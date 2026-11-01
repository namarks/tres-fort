# Plan on the web

Slug: web-app · Status: planned · Updated: 2026-11-01 · Theme: platform

## Goal

A member signs in at `app.tresfort.app` on a laptop or desktop browser with
the same account as the iOS app, and plans their training on a large screen:
sees lifting, runs, rides and other sessions on one calendar, builds and edits
workouts and planned runs, sets the weekly schedule, moves, skips and assigns
dates, and reviews progress. The owner's reason (2026-11-01): planning is
easier on a larger screen. Every web feature works without AI and writes
through the same REST endpoints, versioned writers and audit trail as the app.

The iPhone stays the place to train: the set-by-set runner, run recorder,
Apple Health, iPad Station and partner training are not web features.

## Phases

- [ ] **P0 — Scope and owner setup**
  - The owner confirms who the first version serves (recommended: existing
    members, signing in with Apple) and the P1 to P4 scope.
  - The owner creates a Sign in with Apple **Services ID** grouped with the
    app's primary App ID, so the web and the app receive the same Apple
    `sub` and therefore the same account. Its domain is `app.tresfort.app`
    with a return URL there.
  - The owner approves a new Cloudflare Worker, `tres-fort-web`, on the
    `app.tresfort.app` custom domain.
- [ ] **P1 — Sign in and see the plan**
  - New `web/` package: a static single-page app (TypeScript, React, Vite)
    served by the `tres-fort-web` Worker's static assets. The same Worker is a
    thin same-origin gateway: it completes Sign in with Apple, keeps the app
    JWT in an `HttpOnly`, `Secure`, `SameSite=Strict` cookie that page scripts
    cannot read, and forwards `/api/*` to the API Worker over a service
    binding with the bearer added. Writes require a same-origin `Origin` and a
    custom request header. No CORS is opened on the API Worker.
  - API Worker: `/auth/apple` also accepts the web Services ID as an Apple
    audience (new non-secret `APPLE_WEB_SERVICES_ID` setting) and checks the
    web nonce. Requests from the gateway are audited as `actor='web'`, not
    `'ios'`.
  - Read-only screens: week and month calendar of planned and completed
    sessions across all disciplines, workout details (exercises, targets,
    supersets, planned run steps), away dates, and plan version history.
  - The calendar imports `src/calendarProjection.ts` and run steps import
    `src/runSteps.ts` directly, so the web runs the same code as the Worker
    rather than a third copy of those rules.
  - Sign out, and a link to delete the account (the existing `DELETE /api/me`).
  - Checks: Vitest for gateway and view logic, Playwright against a local
    Worker and D1 at 1280 and 800 px widths, and a keyboard-only pass.
- [ ] **P2 — Edit the plan**
  - Create, edit and delete workouts; add, edit, reorder and remove exercise
    slots with target sets, reps, weight and lb/kg unit, RPE, warm-up flag,
    rest, and superset or circuit groups.
  - Planned run step editor with pace or heart rate targets.
  - Weekly schedule by dragging a workout onto a weekday (with a keyboard
    alternative); assign, move and skip single dates; add, edit and remove
    away dates; restore a past plan version.
  - Every write sends the reviewed plan version. A 409 conflict reloads the
    plan and tells the member it changed elsewhere (the app or the coach)
    before they reapply.
  - Race goal, training phases and deloads follow whatever REST
    [coach-free planning](../coach-free-planning/plan.md) adds; the web does
    not add its own endpoints for them.
- [ ] **P3 — Progress and history**
  - Session history with set detail, exercise history charts, weekly volume,
    the consistency view, and imported and manual activities, including
    typing in a run, ride, swim or walk.
- [ ] **P4 — Profile and connections**
  - Profile and units, training profile, intervals.icu connect and resync,
    AI coach connections (personal passphrase, list and revoke grants), Apple
    Health group sharing switch, data export, and account deletion.
- [ ] **P5 — Release**
  - Privacy policy names the web sign-in cookie (no analytics or tracking);
    the website links to the web app; the owner approves the `tres-fort-web`
    deploy and the API Worker deploy that accepts the web audience.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | gated_by | external:owner-web-app-scope | Who the web app serves and what it covers first are the owner's choices. |
| P1 | gated_by | external:owner-apple-web-services-id | Sign in with Apple on the web needs the owner's Services ID, domain and return URL before it can be tested end to end. |
| P2 | coordinates_with | plan:coach-free-planning | Both add member-facing planning over the same REST endpoints; new endpoints land once and both clients use them. |
| P5 | gated_by | external:owner-web-deploy-approval | A new public site and an API Worker change need the owner's written go-ahead. |
| P5 | coordinates_with | plan:positioning-and-open-source#P4 | Deployer-specific settings (Services ID, domains, Worker names) must follow the same per-deployer pattern as the public snapshot. |

## Next step

**Now (@owner):** Confirm the first-version audience and the P1 to P4 scope,
then create the Sign in with Apple Services ID for `app.tresfort.app`.

## Notes / open questions

- Not in scope: workout runner, run recorder, Apple Health import (a browser
  cannot read HealthKit), iPad Station, partner training, group feed, offline
  use, phone-sized layouts beyond "usable", and sign-in without an Apple ID.
  People without an iPhone would need another sign-in method and a way to log
  workouts; that is a separate decision.
- Size estimate: P1 about three PRs, P2 five to seven (the largest), P3 two to
  three, P4 two. The Worker change is small because the REST API already
  covers planning, history and settings.
- A cheaper stopgap exists for Mac owners: making the iPad app available on
  Apple silicon Macs in App Store Connect. It does not reach Windows or
  Chromebooks, and the layout is the iPad's, so it does not replace this plan.
- Open source: the web app lives in this repository under the same license.
  It makes self-hosting more useful, since a self-hoster cannot easily ship
  their own iOS app.
- A future paid tier would most naturally be sold on the web; this plan adds
  no payments.
