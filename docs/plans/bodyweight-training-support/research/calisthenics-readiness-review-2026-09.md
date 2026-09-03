# Calisthenics readiness review (2026-09-02)

Static review of the worktree at commit `c71e3f9`, cross-checked against
migrations `0001`–`0032`, the vitest suites, the iOS sources, and open GitHub
issues. No probe tests were run against D1. This note is the evidence behind
[`bodyweight-training-support`](../plan.md) and the 2026-09-02 amendments to
[`manual-workout-authoring`](../../manual-workout-authoring/plan.md). It is
history, not a live checklist; the plans own status. Line references are as of
`c71e3f9` and drift.

## Verdict

- Data model and catalog: ready. 254 catalog rows, 84 with modality `bw`,
  5 `timed` holds (plank, side plank, hollow hold, dead hang, wall sit).
  Slots carry nullable `target_weight`, `target_duration_s` on any exercise
  (migration `0010`), `target_reps_max`, and `is_warmup`.
- Runner and history: partial. Bodyweight sets log with weight 0 and render
  "BW × reps" keyed on modality; no added load or assistance; every
  weight-based metric computes to zero for bodyweight work.
- Create without AI: not started. The no-plan screen says "Ask Claude to
  build one" (`ios/TresFort/TodayView.swift:267–271`).

## Capability by surface at c71e3f9

| Action | iOS | REST | MCP |
|---|---|---|---|
| Create a plan from nothing | no | `POST /api/plan` archives the active plan unconditionally | `add_day` auto-creates safely |
| Add / rename a day | no | yes, no audit row; `POST /days` defaults `order_index` 0 | yes |
| Delete a day | no | no route | no tool (`deleteDayTemplate` exists in `db.ts` only) |
| Set the weekly schedule | no | no route (`setPlanSchedule` is service-level) | `set_schedule` |
| Add / remove / reorder a slot | yes | yes | yes |
| Edit targets on an existing slot | no (PATCH used only to reorder) | yes | yes |
| Rep range (`target_reps_max`) | no | yes | yes |
| Hold target on a non-timed exercise | no (editor offers seconds only for modality `timed`) | yes | yes |
| Swap to a harder variation | no | no route | `swap_exercise` |
| Added load or assistance on a `bw` slot | no (weight hidden, pinned to 0) | stored, no convention | stored, no convention |

## Findings

1. **No added load or assistance for bodyweight movements.**
   `ios/TresFort/TodayView.swift:788` hides the weight stepper when
   `isBodyweight`; `ios/TresFort/SyncModel.swift:2814` pins weight to 0;
   `SyncModel.swift:2886,2891` clamp `adjustWeight` / `setWeight` at 0; the
   timed runner commits holds with weight 0 (`SyncModel.swift:2875`). The
   server accepts any finite weight (`src/routes/api.ts:619`) and the
   `log_set` / `add_exercise` descriptions carry no bodyweight convention.
2. **Bodyweight metrics compute to zero.** `getHistory` picks the top set per
   session by Epley on weight; `getVolume` (`src/db.ts:5233`) sums
   `weight × reps`; `ios/TresFort/HistoryView.swift:124–130` shows
   "BEST e1RM". A negative (assisted) weight would subtract from tonnage.
3. **Editor gaps.** `ios/TresFort/EditWorkoutSheet.swift:196–239`: seconds
   only for `timed`, minutes only for `cardio`, no rep-range field, no edit of
   an existing slot; `ios/TresFort/APIClient.swift:294–305` never sends
   `target_reps_max`. The app never decodes `progression`.
4. **Per-set `is_timed` is written by the runner and consumed only by the
   per-set value labels.** `HistoryView.swift:140` gates the duration chart on catalog
   modality; the group feed DTO (`src/db.ts` feed queries) never selects
   `is_timed` or `duration_s`, and `Group/FeedItemDetailSheet.swift:62`
   renders every set as weight × reps.
5. **Catalog gaps.** No ring movement, muscle-up, L-sit, front or back lever,
   handstand hold (only `ex_hspu`), wall walk, crow, skin the cat, dragon
   flag, typewriter or eccentric pull-up, back extension row (`ex_superman`
   carries the alias "back extension bw"), or reverse hyper.
   `test/catalog.test.ts:50–59` and `test/catalog_v2.test.ts:110` both
   assert exactly 254 rows, and both files reject shared or shadowing
   aliases; `ex_dips` owns the plain dip aliases.
6. **Timed auto-log report.** Issues #71 and #92 are re-mirrors of the same
   TestFlight submission as #55 (ASC-ID `AMQS-AA9kc95BweEQFQa7VM`, submitted
   before the fix). #55 was closed by `9a533e8`, which added
   `finishTimedSetAuto` (`SyncModel.swift:2848`) driven by the poll loop in
   `TodayView.swift`. Residual gap: the `.task(id: sync.timedActive)` loop is
   cancelled when the runner view disappears while `timedActive` stays true.
   The duplicates were not filed by `scripts/beta-feedback-to-issues.mjs`,
   whose label (`beta-feedback`) and marker (`asc-feedback`) differ from the
   `testflight-feedback` / `ASC-ID` pair these issues carry.
7. **`swapExercise` ignores `carry_targets`.** `src/db.ts:5087` declares it;
   the body always carries targets; `src/mcp/server.ts:791,801` advertise it.
8. **Circuits, supersets, AMRAP, EMOM** are not representable in the flat slot
   list; `target_reps` is a required integer.

## Manual-authoring hazards in existing server code

- R1 `POST /api/plan` → `createPlan` (`src/db.ts:2354–2358`) archives the
  user's active plan before inserting; a retry after a timeout archives the
  plan just built.
- R2 `deleteDayTemplate` (`src/db.ts:5625–5662`) deletes slots and the day
  without nulling `sessions.day_template_id` or
  `set_logs.template_exercise_id`; `migrations/0001_init.sql` has no
  `ON DELETE` clause; `updatePlanTree` (`src/db.ts:4574–4578`) documents that
  D1 enforces these FKs strictly and remaps before deleting;
  `deleteTemplateExercise` (`src/db.ts:5075`) detaches set logs; the only test
  (`test/calendar.test.ts:795–838`) deletes a never-run day. Nothing exposes
  the function yet.
- R3 `POST /days` and `PATCH /days/:id` (`src/routes/api.ts:211–235`) write
  no audit row; the slot routes do (`api.ts:285,324,338`).
- R4 `POST /days` defaults `order_index` to 0 (`api.ts:217`); MCP `add_day`
  uses `nextDayOrderIndex` (`src/db.ts:2533–2543`).

## What already works and should not be rebuilt

- Bodyweight is a first-class modality in every renderer that uses
  `valueLabel`; "BW" keys off modality, not weight 0 (issue #30 fix).
- Timed holds: hold seconds on the slot, countdown runner, per-set duration
  and `is_timed` (migration `0024`).
- Unilateral bodyweight moves double correctly in rep rollups.
- The in-app editor adds, removes, and reorders slots, including prescribed
  warm-ups, audited and version-bumped through the same service functions
  MCP uses.
- The alias resolver covers the common spoken names.

## Corrections applied after the exact-head review of 77aaded

- Catalog count is 254 (migration `0021` re-lists `ex_kb_swing` as a no-op).
- #71 and #92 duplicate the already-fixed #55; the residual case is the
  view-dismissed countdown, not a regression of the auto-log itself.
- `is_timed` rendering is not universal (finding 4).
- Negative weight needs the iOS clamp lifted and an explicit tonnage rule.
- The manual-authoring P0 walkthrough must not rely on a rep range, since the
  rep-range field belongs to `bodyweight-training-support#P0`.

## Corrections applied after the exact-head review of d795972

- `test/catalog_v2.test.ts:110` asserts the 254-row count as well, and both
  catalog test files carry alias-determinism checks.
- The duplicate issues were not filed by the in-repo `beta:feedback` script;
  the mirror is outside this repository.
- `is_timed` is declared by the runner when it logs and consumed by the
  per-set value labels; the earlier wording inverted that flow.
- Closing the duplicates is in scope; fixing the external mirror is an owner
  question, not a plan deliverable.
