// Universal-Link surface for group invites (the iOS half is the Associated
// Domains entitlement + the deep-link handler in AuthModel/RootView).
//
// Two public, unauthenticated routes:
//   * GET /.well-known/apple-app-site-association (+ /apple-app-site-association)
//       — the AASA file iOS fetches to decide it may open https://<host>/join/*
//         in the app instead of Safari. MUST be application/json with no
//         redirect. The app id is <TeamID>.<bundle id> from ios/project.yml.
//   * GET /join/:code
//       — the Universal-Link target. When the app is installed AND the AASA is
//         live, iOS intercepts the tap and this HTML never renders. It is the
//         FALLBACK for: app not installed, or the link opened directly in
//         Safari. Always 200 so a tapped link never looks broken; the body
//         differs by invite state, and the 6-char code is shown for manual
//         entry on the in-app Join screen.
//
// The authoritative redeem still goes through POST /api/groups/join — this
// file only *advertises* and *previews*; it never mutates.

import { Hono } from 'hono';
import type { HonoEnv } from '../types';
import { getInvitePreview } from '../db';
import { JOIN_CARD_PNG_BASE64 } from '../ogImage';

export const inviteLinkRoutes = new Hono<HonoEnv>();

// <TeamID>.<bundle id>. Keep in lockstep with ios/project.yml
// (DEVELOPMENT_TEAM + the TresFort target's PRODUCT_BUNDLE_IDENTIFIER).
const APP_ID = '8BA2RY6RCA.com.nmarkspdx.tresfort';

const AASA = JSON.stringify({
  applinks: {
    details: [
      {
        appIDs: [APP_ID],
        // Claim only the invite path — everything else (privacy, oauth,
        // api, the bare host) keeps opening in the browser as normal.
        components: [{ '/': '/join/*', comment: 'Group invite links open the join-confirm screen.' }],
      },
    ],
  },
});

function serveAasa(): Response {
  // Hand-built Response so the content-type is exactly application/json with
  // no charset surprises and no chance of a framework redirect — Apple's CDN
  // is strict about both.
  return new Response(AASA, { status: 200, headers: { 'content-type': 'application/json' } });
}

inviteLinkRoutes.get('/.well-known/apple-app-site-association', () => serveAasa());
inviteLinkRoutes.get('/apple-app-site-association', () => serveAasa());

// Brand card used as the og:image for /join/* links — this is what gives a
// shared invite a rich preview thumbnail in Messages/Mail. Static art,
// decoded once per isolate from the embedded base64 (src/ogImage.ts).
const JOIN_CARD_BYTES = Uint8Array.from(atob(JOIN_CARD_PNG_BASE64), (ch) => ch.charCodeAt(0));
inviteLinkRoutes.get('/join-card.png', () =>
  new Response(JOIN_CARD_BYTES, {
    status: 200,
    headers: {
      'content-type': 'image/png',
      // Static, content-addressed by path → cache hard. Link-preview fetchers
      // and Cloudflare's CDN both lean on this.
      'cache-control': 'public, max-age=604800, immutable',
    },
  }),
);

// Mirrors the iOS / invite-code alphabet (no I/L/O/0/1) and the 6-char length.
const INVITE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
function normalizeInviteCode(raw: string): string | null {
  const cleaned = (raw ?? '')
    .toUpperCase()
    .split('')
    .filter((ch) => INVITE_ALPHABET.includes(ch))
    .join('');
  return cleaned.length === 6 ? cleaned : null;
}

// The group name is user-controlled, so it MUST be escaped before landing in
// HTML — otherwise a group named `<script>…</script>` would execute on the
// invitee's device.
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

inviteLinkRoutes.get('/join/:code', async (c) => {
  const raw = c.req.param('code');
  const code = normalizeInviteCode(raw);
  const preview = code
    ? await getInvitePreview(c.env.DB, code)
    : ({ status: 'unknown', group_name: null } as const);
  // Absolute origin (derived from the request, so it's right on any domain)
  // for the absolute og:image / og:url that link-preview fetchers require.
  const origin = new URL(c.req.url).origin;
  return c.html(renderJoinPage(origin, code ?? raw.toUpperCase(), preview));
});

function invalidReason(status: 'valid' | 'used' | 'expired' | 'unknown'): string {
  if (status === 'used') return 'It has already been used.';
  if (status === 'expired') return 'It has expired.';
  return "We couldn't find this invite.";
}

function renderJoinPage(
  origin: string,
  code: string,
  preview: { status: 'valid' | 'used' | 'expired' | 'unknown'; group_name: string | null },
): string {
  const valid = preview.status === 'valid' && preview.group_name != null;
  // Escape ONCE here; safeName is then safe in both HTML body and attributes.
  const safeName = preview.group_name ? escapeHtml(preview.group_name) : null;
  const docTitle = valid && safeName ? `Join ${safeName} · Très Fort` : 'Très Fort invite';
  const ogTitle = valid && safeName ? `Join ${safeName} on Très Fort` : 'Très Fort invite';
  const ogDesc = valid
    ? 'Tap to join and train together — shared workouts, progress, and AI coaching.'
    : 'This invite link is no longer valid.';
  const ogImage = `${origin}/join-card.png`;
  // Escape the code: for a malformed /join/<payload> request `code` is the
  // raw (uppercased) path segment, and this lands in a content="…" attribute.
  const ogUrl = `${origin}/join/${escapeHtml(code)}`;

  const inner = valid
    ? `<p class="lead">You've been invited to join</p>
      <p class="group">${safeName}</p>
      <p class="hint">If the app didn't open automatically, open <b>Très Fort</b> on your iPhone and enter this code on the Join screen:</p>
      <p class="code">${escapeHtml(code)}</p>`
    : `<p class="lead">This invite link is no longer valid</p>
      <p class="hint">${invalidReason(preview.status)} Ask whoever invited you for a fresh link.</p>`;

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${docTitle}</title>
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="Très Fort">
  <meta property="og:title" content="${ogTitle}">
  <meta property="og:description" content="${ogDesc}">
  <meta property="og:image" content="${ogImage}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:url" content="${ogUrl}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${ogTitle}">
  <meta name="twitter:description" content="${ogDesc}">
  <meta name="twitter:image" content="${ogImage}">
  <link rel="icon" href="${ogImage}">
  <style>
    :root { color-scheme: dark; }
    body { font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
           background:#000; color:#fff; margin:0; min-height:100vh;
           display:flex; align-items:center; justify-content:center; padding:2rem; }
    main { max-width: 22rem; text-align:center; }
    h1 { font-size:2rem; letter-spacing:.12em; font-weight:800; margin:0 0 2rem; }
    .lead { color:#8e8e93; margin:.25rem 0; }
    .group { font-size:1.6rem; font-weight:700; margin:.25rem 0 1.25rem; }
    .hint { color:#8e8e93; font-size:.95rem; margin:1.5rem 0 .75rem; }
    .code { font:700 2rem/1 ui-monospace, "SF Mono", Menlo, monospace;
            letter-spacing:.3em; color:#F59E0B; margin:.5rem 0 0; }
  </style>
</head>
<body>
  <main>
    <h1>TRÈS FORT</h1>
    ${inner}
  </main>
</body>
</html>`;
}
