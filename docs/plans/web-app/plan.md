# Plan on the web

Slug: web-app · Status: active · Updated: 2026-11-01 · Theme: platform

## Goal

A member signs in at `app.tresfort.app` on a laptop or desktop browser with
the same account as the iOS app and uses the extra screen space, mouse and
keyboard for two jobs. **Planning:** see lifting, runs, rides and other
sessions on one calendar, build and edit workouts and planned runs, set the
weekly schedule, and move, skip and assign dates. **Analysis:** look at trends
and progress across weeks and months in more depth than a phone allows. The
owner's reason (2026-11-01): planning and reviewing progress are easier with
more screen and a mouse. Every web feature works without AI and writes
through the same REST endpoints, versioned writers and audit trail as the app.

The web is not for training (owner, 2026-11-01). The iPhone stays the place
to train: the set-by-set runner, run recorder, Apple Health, iPad Station and
partner training are not web features.

## Phases

- [x] **P0 — Scope and owner setup**
  - Decided by the owner on 2026-11-01: the app stays iOS-only for now, and
    the first web version serves existing members signing in with Apple.
    Android may come later, so sign-in must stay replaceable (see notes).
    People may also sign up on the web first.
  - Done 2026-11-01: the owner created the Sign in with Apple Services ID
    `com.nmarkspdx.tresfort.web`, grouped with the app's primary App ID
    (`com.nmarkspdx.tresfort`), so the web and the app receive the same
    Apple `sub` and therefore the same account. Its domain is
    `app.tresfort.app` and its return URL is
    `https://app.tresfort.app/auth/apple/callback`.
  - The `tres-fort-web` Worker and its `app.tresfort.app` custom domain are
    created by its first deploy, which needs the owner's written go-ahead.
- [ ] **P1 — Sign in and see the plan**
  - Built first (gateway, sign-in and the read-only month calendar):
    - New `web/` package: a static single-page app (TypeScript, React,
      Vite) served by the `tres-fort-web` Worker's static assets
      (`web/wrangler.jsonc`). The same Worker is a thin same-origin gateway
      (`web/worker/gateway.ts`). It runs Sign in with Apple as a redirect
      with `form_post`, with a fresh state and nonce held in a 10-minute
      `__Host-` cookie. It keeps the app JWT in an `HttpOnly`, `Secure`,
      `SameSite=Lax` `__Host-tf_session` cookie that page scripts cannot
      read, for the JWT's own 60 days. `Lax` rather than `Strict`, because
      Apple's callback is a cross-site POST and the redirect into the app
      after it would not carry a `Strict` cookie. The gateway forwards
      `/api/*` to the API Worker over a service binding with the bearer
      added, only for requests carrying the page's own header from the same
      origin, and passes through only safe headers. It forwards reads only
      for now and never forwards the iPad Station link key. No CORS is
      opened on the API Worker. The gateway and cookie handling do not depend
      on the sign-in provider, so another provider later only adds a
      sign-in route.
    - API Worker: `/auth/apple` also accepts tokens for the non-secret
      `APPLE_WEB_SERVICES_ID` audience, requires the nonce the gateway sends
      to match the token's nonce, and refuses an authorization code with a
      web token. Native sign-in is unchanged.
    - Read-only screens: month calendar of planned and completed lifting
      and endurance sessions with away dates, the weekly routine, and a day
      panel with exercises, targets, supersets and planned run steps. The
      calendar runs `projectCalendarWindow` from `src/calendarProjection.ts`,
      and run steps use `src/runSteps.ts`, so the web runs the same code as
      the Worker rather than a third copy of those rules. Sign out works.
  - Still to do in P1:
    - Plan version history, a week view, and a link to delete the account
      (the existing `DELETE /api/me`).
    - New accounts: `/auth/apple` already creates an ordinary account for
      any new Apple identity, so a person can sign up on the web first. A
      short first-run offers the existing starter workouts and a link to the
      iPhone app for training; a group invite code carries through sign-in
      as it does in the app.
    - Playwright checks against a local Worker and D1 at 1280 and 800 px
      widths, and a keyboard-only pass, kept in the repository.
    - Real Sign in with Apple only works on `app.tresfort.app`, so it is
      checked end to end after the first deploy.
  - Writes from the gateway are audited as `actor='web'`, not `'ios'`; this
    lands in P2 with the first write.
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
- [ ] **P3 — Trends and progress**
  - Equal in importance to plan editing; it can run alongside P2 once P1 is
    in.
  - Session history with set detail; exercise history charts (top set,
    estimated max, volume) with hover detail and a chosen date range;
    weekly training volume and time by discipline; the consistency view;
    imported and manual activities, including typing in a run, ride, swim or
    walk.
  - Comparing periods (this block against the last, planned against done)
    and filtering by discipline or exercise, using existing history and
    volume endpoints first. New read endpoints are added to the Worker only
    where the existing ones cannot answer a chart, and the iOS app can use
    them too.
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
| P0 | gated_by | external:owner-apple-web-services-id | Met 2026-11-01: the owner created the Services ID with its domain and return URL in Apple's developer account. |
| P1 | gated_by | external:owner-web-deploy-approval | Real Sign in with Apple works only on `app.tresfort.app`, so the end-to-end check needs the first `tres-fort-web` deploy and the API Worker's web audience, with the owner's written go-ahead. |
| P2 | coordinates_with | plan:coach-free-planning | Both add member-facing planning over the same REST endpoints; new endpoints land once and both clients use them. |
| P5 | gated_by | external:owner-web-deploy-approval | A new public site and an API Worker change need the owner's written go-ahead. |
| P5 | coordinates_with | plan:positioning-and-open-source#P4 | Deployer-specific settings (Services ID, domains, Worker names) must follow the same per-deployer pattern as the public snapshot. |

## Next step

**Now (@agent):** Land the first P1 pull request (gateway, sign-in and the
read-only calendar), then the rest of P1. The first deploy of
`tres-fort-web` and of the API Worker with `APPLE_WEB_SERVICES_ID` waits
for the owner's written go-ahead.

## Notes / open questions

- Not in scope: workout runner, run recorder, Apple Health import (a browser
  cannot read HealthKit), iPad Station, partner training, group feed, offline
  use, phone-sized layouts beyond "usable", and sign-in without an Apple ID.
  People without an iPhone would need another sign-in method and a way to log
  workouts; that is a separate decision.
- Adding Android or non-Apple sign-in later is contained: all data hangs off
  Tres Fort's own user ID, and Apple's `sub` is one column on `users`. A
  later migration would let one account hold several sign-in identities and
  add a "link another sign-in" screen. Sign in with Apple also works on
  Android through the same Services ID. Members who used Hide My Email cannot
  be matched by email, so linking happens while signed in.
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
- Web sign-in sends Apple no authorization code, because Apple binds the
  code exchange to the Services ID and its own client secret, and the API's
  exchange uses the app's bundle ID. A web-only account therefore has no
  stored Apple refresh token. Deleting it still works and reports
  `manual_required` for Apple's side, as the app already does when no token
  is stored. Exchanging web codes too is a possible follow-up.
