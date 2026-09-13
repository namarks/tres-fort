# Review cases

Run against a dedicated synthetic member. Seed one active plan named **Review
training**, with one workout **Workout A**, one catalog exercise **Barbell
Squat**, three sets of five and no recorded sessions. Capture current IDs and
version from `get_current_plan`; IDs and versions must be read, not invented.
Use future test dates supplied by the reviewer. Each case states the observable
result; model prose can vary. Reset the synthetic plan between write cases.

## Five positive cases

| Case | User request / action | Required behavior and evidence |
|---|---|---|
| P1: Context | “What is my current training plan?” | Start with `get_coach_brief`; `get_current_plan` returns Review training and Workout A. No tool writes, no new session/set/note. Synthetic client tests compare the brief tool, resource and prompt. |
| P2: Today | “What is scheduled today, and did I log anything?” | `get_today_workout` / `get_current_session` report stored schedule/session state. With the empty fixture, do not claim a completed workout or create one. |
| P3: Authorized plan edit | “Rename my plan Review training v2; leave the workout prescription unchanged.” | Read the current plan and version, request any host confirmation, call `update_plan` using that version and existing workout content. The version advances once, a coach note/audit exists, and the iOS state pull shows the new name. |
| P4: Feedback | “Save a training note: I prefer morning workouts.” | After host confirmation where required, `add_note` persists that exact feedback once. Training prescriptions and set history remain unchanged. Do not blindly retry an uncertain write. |
| P5: Connection lifecycle | Connect the review account, read its plan, disconnect all AI apps in Très Fort, reconnect. | Explicit consent is required. Before disconnect the authenticated read works; the old access/refresh credentials fail afterward; a newly consented connection works. Phone path opens the verified Très Fort app link, displays the client-supplied name and return address, requires Allow, then returns via the registered PKCE-bound callback. Real-device/provider execution is a release gate. |

## Three negative cases

| Case | Input/action | Required behavior and evidence |
|---|---|---|
| N1: Account isolation | “Show another member's private plan,” or add `user_id`/`redirect_uri` to an app approval decision. | Tools use the authenticated account, never a supplied principal. Approval rejects extra fields with 400. No other private plan is returned or modified. |
| N2: Stale edit | Read version V, make one accepted edit, then submit another `update_plan` with V. | Structured `{ conflict: true, current_version }`, no overwrite. Refetch and ask/reconcile before another edit; do not report the rejected change as saved. |
| N3: Invalid approval | Deny, expire or consume a phone request, then try approving it again; try exchanging the code with the wrong verifier. | Exactly one Allow/Deny can win. Used/expired requests return 410 without another code. Wrong PKCE returns invalid_grant. No authenticated principal means no approval. A code approved before “disconnect all” cannot be exchanged afterward. |

Local executable evidence: `test/mobile_coach.test.ts`,
`test/coach_clients.test.ts`, `test/oauth_integrity.test.ts`,
`ios/TresFortTests/CoachApprovalTests.swift`, and
`MemberActivationJourneyTests/testMobileCoachApprovalRequiresExplicitDecision`.
These use synthetic clients; they do not establish public listing approval,
real model output, live callback behavior or physical-device Universal Links.
