# Member Activation and Adherence

Slug: member-activation-and-adherence · Status: paused · Updated: 2026-09-12 · Theme: gym-floor

## Goal

Help a newly signed-in or invited member reach a real first workout and return
for the next one without requiring Claude. Done means entry intent survives
authentication, the no-plan state offers honest manual and coach-assisted
paths, and lightweight schedule-based reminders bring the member back to the
correct workout.

## Phases

- [x] **P0 — Reach the first workout**
  - Preserve invite and Coach Connect intent through sign-in, then return the
    member to the intended group or setup action instead of a generic home
    screen.
  - Keep the shipped manual-builder CTA and add a direct coach setup choice.
    Explain both paths and allow either one to be completed later. Reconcile
    signed-out/onboarding/Profile copy: independent and invited members already
    have personal Coach Connect; do not say it is coming soon or that a group
    owner's coach controls another member's plan.
  - Distinguish a verified empty account from initial read failure and cached
    stale state. A cold offline/500 response must offer retry without claiming
    that the member has no plan or encouraging a duplicate replacement.
  - Keep pending invite/coach intent across sign-in and onboarding. Bind async
    step completions to the step that started them so a delayed result after
    Skip cannot advance a different step. Verify owner, invited, independent,
    manual-only and coach-connected entry with the shared synthetic fixtures.
  - Verify the invite, manual, and coach-connected paths through focused
    end-to-end walkthroughs from entry to first completed workout; fix concrete
    breaks without adding an activation analytics system.
- [ ] **P1 — Return for the next workout**
  - Offer opt-in local reminders derived from the existing recurring schedule
    and deep-link each reminder to the correct Today workout.
  - Add a compact Today widget using the same projection and refresh it after
    schedule, skip, completion, or sign-out changes.
  - Keep notification timing and copy editable in app settings; do not require
    a new server notification system for the initial adherence loop.
- [x] **P2 — Deliver a useful starting point**
  - [x] **(a) Training profile and starter workout**
    - Brief, optional setup captures overall goals; all intended activities
      (weightlifting, running, swimming, cycling, walking, yoga and other);
      optional weekly activity context; lifting experience; realistic strength
      time/frequency; equipment; and movements to avoid.
    - Optional recent working sets retain exercise, weight/unit, reps, effort,
      and date. These are user reports, not verified strength or prescriptions.
      Beginners never need a maximum test or a weight estimate.
    - Preview a small curated starter collection filtered by equipment and
      excluded movements. Acceptance creates an editable library workout through
      the shared versioned plan path, never replaces an existing library, and
      is safe to retry after an uncertain response.
    - Keep the account-owned profile independent of plan replacement. Expose it
      in the coach brief/current-plan response and portable export, exclude it
      from group views, and remove it with permanent account deletion.
    - Offer the questionnaire before generic group/integration setup and from
      verified-empty Today. Profile remains editable; interrupted drafts stay
      in the existing protected account-scoped local store.
    - Verify mixed-sport and skip paths, first-workout completion, account
      boundaries, stale saves, transactional rollback, retries and readable
      layouts. Consistency is the guiding message; starters do not prescribe or
      schedule endurance sessions from activity selections alone.

## Next step

**Now (@owner):** P2(a) is implemented and locally verified; its implementation
PR carries exact-head review and CI evidence for repository delivery. Choose
whether to activate P1 reminders/widgets. Migration, production deployment and
iOS distribution remain separately authorized.

## Notes / open questions

- On 2026-09-12 Nick approved the questionnaire plus editable starter approach
  and explicitly requested an overall-fitness activity question. This resolves
  `external:starter-plan-policy` for P2(a). The initial scope emphasizes new and
  returning lifters, includes optional experienced-lifter inputs, and uses
  curated deterministic starters with future connected-coach personalization.
- P2(a) verification covers tenant isolation, profile version conflicts and
  retries, MCP context without a plan, export/deletion, transactional starter
  creation, historical receipt replay, both workout database layouts, and
  already accepted starters after library deletion. The iOS suite passed 548
  unit tests (one existing skip) before recovery refinements; subsequent focused
  runs passed eleven profile-model checks, three empty/session-state checks, and
  journeys covering mixed-sport entry
  through first completion, optional working sets, and skip from absent/empty
  plans. Synthetic screenshots were inspected for readable labels and reachable
  actions. Account refresh fires on acknowledgement even after sheet dismissal;
  a definite conflict retires pending intent so profile editing remains usable.
  Reopening identical server answers after a lost save reply adopts the server
  version before another edit, including normalized selection order/whitespace.
  Questionnaire pages reset their scroll position when advancing/backtracking,
  and primary actions including acknowledgement Continue stay visible at larger
  accessibility text sizes. The mixed-sport, working-set and empty-entry journeys
  passed with accessibility-large text after the navigation correction. Empty-library starter entry preserves
  recovery for a real planned/in-progress session, including a plan emptied by
  another client; recorded sets and the workout record remain accessible.
  Skip/Close remain available during unanswered reads, profile saves, preview
  reads and starter acceptance. Dismissal invalidates late UI updates while
  retaining protected drafts and recoverable starter intent. An unreadable
  protected draft exposes an explicit restore-from-server action. Today checks
  the server's durable starter capability so deleting a previously accepted
  starter does not advertise another acceptance. The final focused recovery run
  passed twelve model tests and four journeys covering these boundaries. A
  subsequent dismissal run passed all eleven profile-model tests and both UI
  tests spanning the four deliberately stalled network stages.
  Full CI and fresh independent review remain mandatory merge checks.
- Source base: verified remote main `90f968383629107bd7a95b37bd44da177f87305f`.
  Starter/profile delivery requires additive migration `0051_training_profile`
  before the compatible Worker and then the app. Existing staged migration
  instructions still apply to earlier migrations; this change does not approve
  a production release or change the workout-rename rollout order.


- P0 was activated from verified main `4ec8a9e`; reconciliation preserved the
  shipped manual builder and returned-error recovery. This change closes the
  remaining entry-intent, capability-copy, initial-read and delayed-callback gaps.
- Pending invite, coach and manual setup destinations persist through failed
  sign-in/relaunch, bind to the authenticated account and are consumed once at
  sheet dismissal. Onboarding completion is account-scoped; unfinished setup
  survives relaunch. Step/feature-session checkpoints reject late completions
  after Skip, reauthentication or account changes.
- Today and direct manual setup require an accepted live read before offering
  empty-account creation. Cold offline/500 and cached-empty states offer retry;
  an existing cached plan remains available under the existing freshness rules.
- Coaching Feedback Loop P1 is integrated from main `4828842` (PR #164), whose
  reviewed tree and main CI were verified. Its recent-change card, permanent
  history entry, account-bound dismissal and private feedback remain intact.
- Verification: 431 iOS unit tests; nine existing manual/onboarding,
  coaching-feedback and plan-change journeys; and all eight new
  `MemberActivationJourneyTests` journeys passed locally (including a focused
  rerun after correcting the combined handoff test's heading selector).
  New journeys cover owner, invited, independent/manual-only and connected-coach
  entry through first completion, sign-in/invite-preview retry, cold offline/500,
  cached empty/existing state, and sequential invite/coach handoff. Model tests
  cover interrupted onboarding relaunch and late completions after Skip/account
  boundaries. All 17 verification-command/scope tests and the plan graph passed.
  The activation journeys are included in standard CI smoke coverage; exact-head
  independent review and terminal-green CI are required before this change merges.
- Repository delivery is the P0 boundary. Production deployment/migrations,
  TestFlight distribution and actual member messages remain separately
  authorized. Existing physical-device coaching feedback checks remain release
  follow-up; no new pre-merge device gate is introduced here.

- The [September app review](../../reviews/2026-09-app-review/report.md)
  revalidated the working manual entry path. P0 closes remaining intent,
  capability-copy and error-state gaps rather than rebuilding manual authoring.

- P0 does not require a user to choose between AI and manual control forever.
  Both paths converge on the same active plan and can be used later.
- The initial adherence loop is local and schedule-driven. Social campaigns,
  generalized push automation, and predictive churn scoring are out of scope.
