# Plan on the web

Slug: web-app · Status: active · Updated: 2026-11-02 · Theme: platform

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
    - A week view, and a link to delete the account (the existing
      `DELETE /api/me`). Plan version history is built with P2's restore,
      below.
    - New accounts: `/auth/apple` already creates an ordinary account for
      any new Apple identity, so a person can sign up on the web first. A
      short first-run offers the existing starter workouts and a link to the
      iPhone app for training; a group invite code carries through sign-in
      as it does in the app.
    - Playwright checks against a local Worker and D1 at 1280 and 800 px
      widths, and a keyboard-only pass, kept in the repository.
  - Writes from the gateway are audited as `actor='web'`, not `'ios'`
    (built with the first P2 write, below).
  - Released 2026-11-02 with the owner's written go-ahead: migrations 0059
    and 0060 were applied in production, then the API Worker (version
    89bfec82, rollback target af46e7a3) and `tres-fort-web` on
    `app.tresfort.app` (version d9cd2ddb) were deployed from main ab21d04.
    The owner signed in with Apple there and saw their plan, which checks
    the shared Apple `sub` end to end.
- [ ] **P2 — Edit the plan**
  - Built first (owner chose plan editing next on 2026-11-02): a Workouts
    view to create, rename, tag, add notes to, archive, restore and delete
    workouts; add exercises and warm-ups from a searchable catalog; edit a
    slot's sets, reps or rep range, hold or cardio duration, weight with its
    lb or kg unit, target RPE, rest and warm-up flag; replace, reorder and
    remove slots. Group members are editable, but their rounds and rests
    stay group-owned. The gateway forwards only those writes (an allowlist of
    method and path), each with the page's own origin and header and a JSON
    body of at most 64 KB. A web sign-in's app JWT carries `client: 'web'`,
    so the API records `actor='web'` on audit rows and plan versions; a
    session from before that claim is signed out once. Every write sends the
    version on screen; a 409 reloads the plan, closes any open form and says
    the plan changed elsewhere. Moving a slot after another was removed now
    works for the app too: a gap in stored indexes made the move a no-op.
  - Built next: supersets and circuits (tick two or more neighboring
    exercises, then set rounds, rest between exercises and rest after each
    round; edit, ungroup, move the whole group, and reorder exercises within
    it) through `PUT /api/workouts/:id/groups`, and moving workouts up and
    down the list.
  - Then the run step editor: a run's steps and repeats, each ending after a
    time or a distance with an optional pace (per mile or kilometer, by the
    browser's region) or heart rate range, checked with the Worker's own
    `parseRunSteps` and saved as the slot's `run_steps`. Stored distances and
    paces are kept exactly until their text changes; steps in a format the
    web can't read can only be removed.
  - Then the calendar: the weekly routine (a menu per weekday, or dragging a
    workout or Rest onto a weekday; each change sends the whole week with
    the plan version), single dates (choose another workout, move it to a
    later empty date, or make it a rest day, each checked against the
    date's `sessions.attempt` as the app does; past, started and
    away-without-training dates stay as they are), and away dates (add,
    edit only the changed fields, and remove, with the plan version).
  - Then plan changes: every saved version, newest first, with who changed
    it (the coach, the app or the web), the coach's reason and what it
    touched. Choosing one compares it with the plan now, field by field;
    restoring it sends the plan ID and the version it was compared with,
    and saves it as a new version, so the replaced plan stays in the list.
    A plan changed elsewhere since the comparison is refused and reloaded,
    and a workout in progress in the app blocks a restore.
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
| P1 | gated_by | external:owner-web-deploy-approval | Met 2026-11-02: the owner approved the first deploy in writing and signed in with Apple on `app.tresfort.app`. |
| P2 | coordinates_with | plan:coach-free-planning | Both add member-facing planning over the same REST endpoints; new endpoints land once and both clients use them. |
| P5 | gated_by | external:owner-web-deploy-approval | A new public site and an API Worker change need the owner's written go-ahead. |

## Next step

**Now (@agent):** P2's editing is built: workouts, slots, groups, run
steps, the calendar and restoring a plan version. It waits for review and
the owner's written go-ahead to deploy (the API Worker and `tres-fort-web`
together). Race goal, training phases and deloads follow coach-free
planning's REST. The rest of P1 (plan
history, week view, delete-account link, first-run for web sign-ups, invite
codes, committed browser checks) follows before the site is linked publicly
in P5. Each later deploy needs the owner's written go-ahead.

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
