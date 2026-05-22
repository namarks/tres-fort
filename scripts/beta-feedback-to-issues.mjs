#!/usr/bin/env node
// Mirror TestFlight beta feedback into GitHub issues.
//
// Pulls screenshot + crash feedback from App Store Connect and opens one
// GitHub issue per submission. Idempotent: each issue body carries an
// `<!-- asc-feedback:<id> -->` marker and existing issues are scanned for it,
// so re-running never creates duplicates. Safe to run on a schedule.
//
// Auth (no secrets committed — same model as upload-testflight.sh):
//   - App Store Connect: the account-level API key .p8 on disk. Only the
//     key id / issuer id (non-sensitive) live here.
//   - GitHub: the `gh` CLI, using your existing login. The repo is taken
//     from `gh repo view` in the current directory, or the REPO env var.
//
// Usage:
//   node scripts/beta-feedback-to-issues.mjs            # file issues for new feedback
//   node scripts/beta-feedback-to-issues.mjs --dry-run  # print what would be filed
//   REPO=owner/name node scripts/beta-feedback-to-issues.mjs
//
// Requires: an ASC API key at ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8
// and an authenticated `gh`.

import crypto from "node:crypto";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

// Account-level ASC API key — same one upload-testflight.sh and the Fastfile
// use (team 8BA2RY6RCA). These ids are not secret; the .p8 stays on disk.
const KEY_ID = "723T6CFSD9";
const ISSUER_ID = "b169cd8d-cb73-4efc-8d72-8c92c5ad29ed";
const BUNDLE_ID = "com.nmarkspdx.liftcoach";
const P8_PATH = join(homedir(), ".appstoreconnect", "private_keys", `AuthKey_${KEY_ID}.p8`);
const LABEL = "beta-feedback";
const DRY_RUN = process.argv.includes("--dry-run");

function ascToken() {
  let p8;
  try {
    p8 = readFileSync(P8_PATH, "utf8");
  } catch {
    fail(`Missing ASC API key at ${P8_PATH}`);
  }
  const b64 = (b) => Buffer.from(b).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const header = b64(JSON.stringify({ alg: "ES256", kid: KEY_ID, typ: "JWT" }));
  const payload = b64(
    JSON.stringify({ iss: ISSUER_ID, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }),
  );
  const signingInput = `${header}.${payload}`;
  const sig = crypto.sign("sha256", Buffer.from(signingInput), {
    key: p8,
    dsaEncoding: "ieee-p1363", // JOSE wants raw r||s, not DER
  });
  return `${signingInput}.${b64(sig)}`;
}

async function asc(token, path) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const json = await res.json().catch(() => ({}));
  if (res.status !== 200) {
    fail(`ASC ${path} -> ${res.status}: ${JSON.stringify(json).slice(0, 400)}`);
  }
  return json;
}

// Walk every page of a list endpoint, gathering data + included resources.
// Follows links.next until exhausted so a large first-time backfill is never
// silently truncated. MAX_PAGES is only a runaway guard (≈50k submissions at
// limit=50) and fails LOUDLY rather than dropping data if ever hit.
const MAX_PAGES = 1000;
async function ascAll(token, startPath) {
  const data = [];
  const included = [];
  let path = startPath;
  for (let page = 0; path; page++) {
    if (page >= MAX_PAGES) {
      fail(`ASC pagination exceeded ${MAX_PAGES} pages for ${startPath} — aborting (runaway guard)`);
    }
    const body = await asc(token, path);
    data.push(...(body.data || []));
    included.push(...(body.included || []));
    const next = body.links?.next;
    path = next ? next.replace("https://api.appstoreconnect.apple.com", "") : null;
  }
  return { data, included };
}

function gh(args, opts = {}) {
  return execFileSync("gh", args, { encoding: "utf8", ...opts });
}

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

function resolveRepo() {
  if (process.env.REPO) return process.env.REPO;
  try {
    return gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).trim();
  } catch {
    fail("Could not determine repo. Run inside the git repo or set REPO=owner/name.");
  }
}

// Existing issues already filed from feedback, keyed by ASC submission id.
// Fully paginated so the dedup scan never silently drops older `asc-feedback`
// markers once the repo has many mirrored issues — `gh issue list --limit N`
// would cap. `--paginate --jq` applies the filter per page and concatenates,
// yielding newline-delimited JSON across all pages (plain `--paginate` would
// emit one separate JSON array per page, which JSON.parse can't read; `--slurp`
// can't be combined with `--jq`). Filtering by the beta-feedback label scopes
// it to feedback issues (and excludes PRs, which the issues endpoint otherwise
// returns); an absent label just yields nothing.
function existingFeedbackIds(repo) {
  const out = gh([
    "api", "--paginate",
    `repos/${repo}/issues?state=all&labels=${LABEL}&per_page=100`,
    "--jq", ".[] | {number, body}",
  ]);
  const ids = new Map();
  for (const line of out.split("\n")) {
    if (!line.trim()) continue;
    const it = JSON.parse(line);
    const m = (it.body || "").match(/<!--\s*asc-feedback:([^\s>]+)\s*-->/);
    if (m) ids.set(m[1], it.number);
  }
  return ids;
}

// Provision every label the run may apply. Crash submissions add `crash`; if
// it didn't exist, `gh issue create` would fail on the first crash and abort
// the whole sync, so create it up front alongside beta-feedback.
function ensureLabels(repo) {
  if (DRY_RUN) return;
  const defs = [
    [LABEL, "D93F0B", "Auto-filed from TestFlight beta feedback"],
    ["crash", "B60205", "TestFlight crash feedback"],
  ];
  for (const [name, color, description] of defs) {
    try {
      gh(["label", "create", name, "--repo", repo, "--color", color,
        "--description", description], { stdio: "ignore" });
    } catch {
      // already exists — fine
    }
  }
}

function truncate(s, n) {
  s = (s || "").replace(/\s+/g, " ").trim();
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}

function buildVersionFor(sub, buildsById) {
  const id = sub.relationships?.build?.data?.id;
  return id && buildsById.get(id) ? buildsById.get(id).version : null;
}

function testerNameFor(sub, testersById) {
  const id = sub.relationships?.tester?.data?.id;
  const t = id && testersById.get(id);
  if (!t) return null;
  const name = [t.firstName, t.lastName].filter(Boolean).join(" ").trim();
  return name || t.email || null;
}

function metaTable(a, build, tester) {
  const rows = [
    ["Submitted", a.createdDate],
    ["Build", build ? `${build}` : a.buildBundleId || "—"],
    ["Device", [a.deviceModel, a.osVersion && `iOS ${a.osVersion}`].filter(Boolean).join(" · ")],
    ["Locale / TZ", [a.locale, a.timeZone].filter(Boolean).join(" · ") || "—"],
    ["Tester", tester || a.email || "—"],
  ];
  if (a.batteryPercentage != null || a.appUptimeInMilliseconds != null) {
    const battery = a.batteryPercentage != null ? `${a.batteryPercentage}%` : null;
    const uptime =
      a.appUptimeInMilliseconds != null ? `${Math.round(a.appUptimeInMilliseconds / 1000)}s uptime` : null;
    rows.push(["State", [battery, uptime].filter(Boolean).join(" · ")]);
  }
  return ["| Field | Value |", "|---|---|", ...rows.map(([k, v]) => `| ${k} | ${v} |`)].join("\n");
}

function screenshotBlock(a) {
  if (!a.screenshots?.length) return "";
  const lines = a.screenshots.map((s, i) => {
    const exp = s.expirationDate ? ` (link expires ${s.expirationDate})` : "";
    return `- [Screenshot ${i + 1}](${s.url})${exp}`;
  });
  return `\n**Screenshots**${a.screenshots[0].expirationDate ? " — Apple-hosted, time-limited" : ""}:\n${lines.join("\n")}\n`;
}

function makeIssue(kind, sub, build, tester) {
  const a = sub.attributes;
  const comment = (a.comment || "").trim();
  const isCrash = kind === "crash";
  const title = isCrash
    ? `[Beta crash] ${truncate(comment || `${a.deviceModel || "device"} · iOS ${a.osVersion || "?"}`, 70)}`
    : `[Beta] ${truncate(comment || "(screenshot, no comment)", 70)}`;
  const crashBlock = isCrash && a.crashLog?.url ? `\n**Crash log** (expires ${a.crashLog.expirationDate || "soon"}): ${a.crashLog.url}\n` : "";
  const body = [
    comment ? `> ${comment}` : "_(no comment provided)_",
    "",
    metaTable(a, build, tester),
    screenshotBlock(a),
    crashBlock,
    "---",
    "_Filed automatically from App Store Connect → TestFlight → Feedback._",
    `<!-- asc-feedback:${sub.id} -->`,
  ].join("\n");
  return { title, body, labels: isCrash ? [LABEL, "crash"] : [LABEL] };
}

async function collect(token, appId) {
  const out = [];
  for (const [kind, resource] of [
    ["screenshot", "betaFeedbackScreenshotSubmissions"],
    ["crash", "betaFeedbackCrashSubmissions"],
  ]) {
    const { data, included } = await ascAll(
      token,
      `/v1/apps/${appId}/${resource}?limit=50&sort=-createdDate&include=build,tester`,
    );
    const buildsById = new Map(included.filter((x) => x.type === "builds").map((b) => [b.id, b.attributes]));
    const testersById = new Map(included.filter((x) => x.type === "betaTesters").map((t) => [t.id, t.attributes]));
    for (const sub of data) {
      out.push({ kind, sub, build: buildVersionFor(sub, buildsById), tester: testerNameFor(sub, testersById) });
    }
  }
  return out;
}

async function main() {
  const repo = resolveRepo();
  const token = ascToken();

  const apps = await asc(token, `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
  const app = apps.data?.[0];
  if (!app) fail(`No App Store Connect app for bundle ${BUNDLE_ID}`);
  console.log(`App: ${app.attributes?.name} (${app.id}) → ${repo}`);

  const feedback = await collect(token, app.id);
  console.log(`Found ${feedback.length} feedback submission(s) in App Store Connect.`);
  if (!feedback.length) return;

  const existing = existingFeedbackIds(repo);
  ensureLabels(repo);

  let created = 0;
  for (const { kind, sub, build, tester } of feedback) {
    if (existing.has(sub.id)) {
      console.log(`  skip ${sub.id} — already issue #${existing.get(sub.id)}`);
      continue;
    }
    const { title, body, labels } = makeIssue(kind, sub, build, tester);
    if (DRY_RUN) {
      console.log(`\n  WOULD CREATE [${labels.join(",")}] ${title}\n${body.replace(/^/gm, "    ")}`);
      created++;
      continue;
    }
    const tmp = join(mkdtempSync(join(tmpdir(), "asc-fb-")), "body.md");
    writeFileSync(tmp, body);
    const labelArgs = labels.flatMap((l) => ["--label", l]);
    const url = gh([
      "issue", "create", "--repo", repo,
      "--title", title, "--body-file", tmp, ...labelArgs,
    ]).trim();
    console.log(`  created ${url}`);
    created++;
  }
  console.log(`\n${DRY_RUN ? "[dry-run] " : ""}${created} new, ${feedback.length - created} already filed.`);
}

main().catch((e) => fail(e?.stack || String(e)));
