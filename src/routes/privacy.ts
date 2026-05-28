// GET /privacy — Privacy Policy page.
//
// Hosted from the Worker so the URL is stable for App Store Connect (and
// any future store listing): https://tres-fort.nmarkspdx.workers.dev/privacy.
// No external hosting / GitHub Pages dependency — ships with the Worker.
//
// Content is intentionally plain HTML (no framework, no CSS file): a single
// inline <style> block keeps it readable on phone screens, and the entire
// page weighs in at <10kB so it loads instantly even on flaky reviewer wifi.
// When the policy changes, update both the body text AND the
// "Last updated" date at the top.

import { Hono } from 'hono';
import type { HonoEnv } from '../types';

export const privacyRoutes = new Hono<HonoEnv>();

const LAST_UPDATED = '2026-05-28';
const CONTACT_EMAIL = 'nmarkspdx@gmail.com';

const PRIVACY_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Très Fort — Privacy Policy</title>
  <style>
    body { font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
           max-width: 720px; margin: 2rem auto; padding: 0 1.25rem; color: #1a1a1a; }
    h1 { font-size: 1.8rem; margin: 0 0 .25rem; }
    h2 { font-size: 1.15rem; margin: 1.8rem 0 .4rem; }
    .meta { color: #666; font-size: .9rem; margin-bottom: 1.5rem; }
    ul { padding-left: 1.25rem; }
    li { margin: .25rem 0; }
    code { background: #f3f3f3; padding: 1px 4px; border-radius: 3px; font-size: .92em; }
    a { color: #0066cc; }
  </style>
</head>
<body>
  <h1>Privacy Policy</h1>
  <p class="meta">Très Fort (iOS) · Last updated ${LAST_UPDATED}</p>

  <p>Très Fort is a personal-fitness app operated by Nicholas Marks. This page
    describes exactly what the app collects, how it is used, and your
    options. No analytics SDKs, no ad tracking, no data brokers.</p>

  <h2>What we collect</h2>
  <ul>
    <li><strong>Account identity</strong> — from Sign in with Apple: your
      Apple subject identifier, email (which may be a private relay address),
      and optional display name. Apple is the identity provider; we only see
      what you authorise.</li>
    <li><strong>Training data you log</strong> — strength sessions, sets,
      weight, reps, RPE, perceived fatigue, free-text notes; generic activity
      log entries (Pilates, yoga, jump rope, etc.) with optional notes.</li>
    <li><strong>Group membership</strong> — if you join or create a group,
      your group memberships and an optional per-group display name.</li>
    <li><strong>Intervals.icu credentials (optional)</strong> — your
      intervals.icu API key and athlete id, only if you choose to connect
      that integration. Used solely to read your cycling activities and
      write back lifting load. Stored encrypted at rest on Cloudflare D1.</li>
    <li><strong>Device timezone</strong> — sent with each request so the
      server interprets "today" consistent with your phone's clock.</li>
  </ul>

  <h2>What we do NOT collect</h2>
  <ul>
    <li>Location, contacts, photos, microphone, camera, or HealthKit data.</li>
    <li>Advertising identifiers (IDFA) or any cross-app tracking.</li>
    <li>Crash analytics or behavioural telemetry.</li>
  </ul>

  <h2>How your data is used</h2>
  <ul>
    <li>To run the app: storing your plan, sets, and activity history.</li>
    <li>To enable AI coaching: when you chat with Claude through the
      Anthropic Model Context Protocol (MCP), Claude reads your training
      data to give context-aware advice. Anthropic's privacy practices
      govern that conversation; see
      <a href="https://www.anthropic.com/legal/privacy">Anthropic's Privacy
      Policy</a>.</li>
    <li>To enable group accountability (if you join a group): other members
      of that group can see a summary feed of your recent workouts —
      session names, top sets, ride/activity metrics, and your free-text
      activity titles/notes. We do <strong>NOT</strong> share your strength-session notes,
      per-set notes, or perceived-fatigue ratings with group members — those
      remain private to you.</li>
    <li>To sync optional integrations: if you connect intervals.icu, we read
      your activities and write back lifting load to your account there.</li>
  </ul>

  <h2>Who can see your data</h2>
  <ul>
    <li><strong>You.</strong> Via the iOS app.</li>
    <li><strong>Anthropic / Claude</strong> — only when you initiate a chat
      that reads your training data via MCP.</li>
    <li><strong>Other members of any group you join</strong> — limited to
      the summary feed described above; never your private notes.</li>
    <li><strong>Intervals.icu</strong> — only the activities you authorise
      via the connection you set up.</li>
    <li>The operator (Nicholas Marks) for the purpose of running and
      supporting the service. No data is sold, rented, or shared with
      advertisers.</li>
  </ul>

  <h2>Where your data lives</h2>
  <p>Data is stored on Cloudflare D1 (a SQLite-based service running on
    Cloudflare's global network). Traffic between your device and the
    backend is TLS-encrypted.</p>

  <h2>Retention and deletion</h2>
  <ul>
    <li>Your account and all training data persist until you request
      deletion.</li>
    <li>To delete your account and all associated data, email
      <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a>. Deletion is
      permanent and typically processed within seven days.</li>
    <li>If you disconnect intervals.icu in the app, your credentials are
      cleared immediately; subsequent sync attempts stop.</li>
  </ul>

  <h2>Children</h2>
  <p>Très Fort is not directed at children under 13 and is not appropriate
    for that audience. We do not knowingly collect data from minors.</p>

  <h2>Changes to this policy</h2>
  <p>If this policy changes materially, the "Last updated" date above will
    reflect the change. Continued use of the app after that date constitutes
    acceptance of the revised policy.</p>

  <h2>Contact</h2>
  <p>Questions, data-deletion requests, or anything else: email
    <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a>.</p>
</body>
</html>`;

privacyRoutes.get('/privacy', (c) => c.html(PRIVACY_HTML));
