# Multisport M0 — verification outcome & live-spike runbook

Companion to [`MULTISPORT.md`](MULTISPORT.md). Output of the M0 verification
pass (run/swim `POST /events` shape, the CTL round-trip, webhook availability).
This is the **go/no-go on the endurance write bridge (M5)** plus the concrete
spike Nick must run against a real intervals.icu account to close the
live-only unknowns. Source: code-grounded review of `src/intervals.ts` /
`src/db.ts` + intervals.icu API docs.

## Verdict — M5 write bridge: **CONDITIONAL (NO-GO now, GO later)**

Do **not** build `schedule_endurance` + write-through yet. Build it later, gated
on all three clearing:

1. The **live spike below passes** (round-trip + delete confirmed, `type`
   casing confirmed, re-ingestion behavior observed, load-honored-vs-overwritten
   settled).
2. **M2 (durable `meta.*`) and M4 (composite calendar + provenance column +
   brick-aware `detectConflicts`) have shipped first** — the doc's own §10 order.
3. A **concrete planning pain point** exists that verbal coordination off the
   reads cannot cover.

Rationale: the write primitive itself is low-risk (a planned Run/Swim is the
same endpoint/auth/idempotency as the verified `WeightTraining` export — only
the `type` enum changes). But nothing forces building it now, two findings argue
for sequencing it behind cheaper work, and **the athlete isn't on intervals.icu
yet (R0)** — so M5's value is currently zero regardless of build risk.

## The three findings

| Thread | Verdict | What it means |
|---|---|---|
| **POST shape (run/swim)** | **likely** | Same `POST /api/v1/athlete/{id}/events`, `category:"WORKOUT"`, HTTP Basic `API_KEY:key` or Bearer, idempotent by `external_id` — only `type` becomes `"Run"`/`"Swim"`. `moving_time`/`distance`/`icu_training_load`/`icu_intensity`/`description`/`external_id` field names confirmed. Live-only unknowns remain (see spike). |
| **CTL round-trip** | **REFUTED** | The "unified load gauge" is **false as built.** intervals computes actual CTL/Fitness from **completed activities only**; a planned event projects the future curve but does not move actual CTL. Worse, completed `WeightTraining` is excluded from Fitness by default (Fatigue only) unless a per-sport setting is flipped. → The planner must own its **own** combined-load model — i.e. the §4.4 `stress_model` (shipped in M2) is now the **primary** planning substrate, not a fallback. |
| **Webhooks** | **confirmed** | intervals.icu fires outbound `ACTIVITY_UPLOADED`, `ACTIVITY_ANALYZED`, `CALENDAR_UPDATED`, `SPORT_SETTINGS_UPDATED` POSTs to a callback URL on the OAuth app (#431). Replaces the 15-min poll. **Caveat:** "activity webhooks are not delivered for Strava activities" — if the dad's rides arrive via Strava, the poll stays as fallback. Confirm with david. |

Bonus: **M1 is already shipped in-tree** — `grant_type=refresh_token` exchange
(`db.ts:4202-4255`) and 401/403 disconnect+reauth (`fetchIntervalsWithAuthRecovery`,
`db.ts:4264`; commit `6bc3264`). §10 M1 / §12 R3 should be relabeled "shipped."

## Live-spike runbook (Nick runs this — needs a real intervals.icu account)

Use your **own** intervals account (doesn't need to be the dad's). Get the API
key (Settings → Developer) for HTTP Basic, or a valid OAuth bearer for app #431,
and your numeric athlete id. Use a throwaway near-future date (5–7 days out).
Keep a scratch file of every raw JSON response.

1. **Baseline (for CTL check):** `GET /api/v1/athlete/{id}/wellness/{recent-past-date}` → record `ctl, atl, ctlLoad, atlLoad`.
2. **Create RUN:** `POST /events` `{"start_date_local":"<date>T00:00:00","name":"SPIKE Z2 Run","category":"WORKOUT","type":"Run","moving_time":3600,"icu_intensity":0.70,"icu_training_load":50,"description":"60min easy aerobic.","external_id":"tresfort:spike:run1"}`. Observe: status 200/201; does the response echo a numeric `id`? (confirms write-through keying). Save the response.
3. **Read RUN back** two ways — `GET /events/{id}` and `GET /events?oldest=<date>&newest=<date>`. Observe: is `icu_training_load` still 50 or **overwritten/nulled**? Is `icu_intensity` still 0.70? Is the prose `description` verbatim? Did `type` come back exactly `"Run"`, `category` still `"WORKOUT"`?
4. **Create SWIM (distance + prose):** `POST /events` `{"...","type":"Swim","moving_time":2700,"distance":2000,"description":"...6x100 @ 2:30...","external_id":"tresfort:spike:swim1"}`. Observe: `type:"Swim"` accepted as-is? Does `distance` (2000m) round-trip alongside `moving_time` or is one derived?
5. **PUT-update idempotency:** `PUT /events/{run-id}` same body, `moving_time:4200`. Confirm the **same id** shows new values (in-place, not a dup). Then `GET` the date window and confirm you can find your event by `external_id=="tresfort:spike:run1"` (the exact lookup `pushStrengthActivity` relies on).
6. **CTL refutation (~10 min):** `POST` a `WeightTraining` event on a recent **past** date with `icu_training_load:80`, `external_id:"tresfort:spike:ctl1"`. Wait 1–2 min, re-`GET` wellness for that date. **Expected: ctl/ctlLoad unchanged** → confirms the gauge is refuted as built. Also `GET .../sport-settings` to record whether WeightTraining counts toward fitness.
7. **Re-ingestion/provenance:** if you can trigger the local sync (`npm run dev` + scheduled handler, or call `syncExternalEvents`), inspect `external_events`. A `tresfort:spike:*` WORKOUT is **not** matched by `isTresFortExport` (`intervals.ts:361-369`), so it flows back in as a normal endurance row — confirm that's the desired policy before deciding the exclusion.
8. **DELETE cleanup:** `DELETE /events/{run-id}`, `{swim-id}`, `{ctl1-id}` (bulk: `DELETE /events/bulk` `{"ids":[...]}`). Confirm 2xx and the window no longer returns them. Leave no SPIKE events behind.
9. **Write up the fixture:** commit the step-2/step-4 create responses + the step-3 window element as M5 contract fixtures (matches the `raw` column shape `fetchPlannedEvents` stores). Build M5 test-first against these.

## `MULTISPORT.md` corrections (apply before M5; the gauge is load-bearing)

- **§1 ownership table (line 114)** — "Unified aggregate load … intervals.icu" is the design *intent*, not current behavior. Add the caveat (refuted as built; contingent on step-6 + per-sport setting).
- **§5.3 (302-308)** — strength export to a planned WORKOUT does **not** feed Fitness as built. Demote to "projects the fitness curve only" or flip to a verified completed-activity write path.
- **§7 (400-402)** — the aggregate gauge premise is refuted; the decision to plan over `stress_model` is **strengthened** — make it the primary (not preferred) substrate.
- **§8 sync table (437)** — webhooks **answered: available** (`ACTIVITY_*`, `CALENDAR_UPDATED`, `SPORT_SETTINGS_UPDATED`). Update "Verify-then-maybe" → "Available — provisioning + Strava-exclusion caveat pending david."
- **§9 (454)** — note `get_fitness` is unbuilt and would surface the refuted gauge; build against the corrected own-load model or drop from scope.
- **§10 M5 (472) + footnote (474-477)** — mark M5 CONDITIONAL/deferred (this M0's conclusion). Update M1/§12 R3 from "NOT HANDLED/HIGH" → "shipped — verify in spike."
- **§12 R1 (503-506)** — split: POST-shape half → Low (post-spike); CTL half → a refuted *finding*, not an open question.
- **Must-fix #4 / #5** — still open, both M4: `external_events.source` hardcoded `'intervals'` (no provenance, `db.ts:4439`); `detectConflicts` flags every brick as `clash` (`db.ts:4819`).

## Draft email to david@intervals.icu

> **Subject:** intervals.icu API questions — planned endurance writes + webhooks (OAuth app #431)
>
> Hi David,
>
> I build Très Fort, an AI strength-coaching app that integrates with intervals.icu via OAuth app client_id 431. It already exports completed strength sessions to your `/events` endpoint as WeightTraining WORKOUT events, and reads planned events + completed activities back. I'm scoping two extensions and want to confirm a few things so I build them correctly rather than guess.
>
> **Planned endurance writes:**
> 1. To place a planned run or swim, I plan to POST to `/api/v1/athlete/{id}/events` with category `"WORKOUT"` and type `"Run"`/`"Swim"` (same shape as my working WeightTraining export, only the type differs). Is `"Run"`/`"Swim"` the accepted type token, or do you expect a different value (e.g. `VirtualRun`)?
> 2. If I send an explicit `icu_training_load` (and `icu_intensity`) on a planned Run/Swim, do you preserve it, or derive/overwrite from the athlete's pace/HR thresholds?
> 3. For a planned swim I'd send both `moving_time` (s) and `distance` (m). Independent, or is one derived?
> 4. I store freeform prose `description` (e.g. "6x100 @ 2:30, 20s rest"), not structured steps. Preserved verbatim, or stripped/rejected when unparseable?
>
> **Load / fitness model:**
> 5. To confirm: a planned calendar EVENT carrying `icu_training_load` projects the future fitness curve but does NOT move actual CTL/Fitness (computed from completed activities only) — and WeightTraining is excluded from Fitness by default (Fatigue only) unless the athlete flips a per-sport setting. Correct?
>
> **Webhooks (would replace my 15-min poll):**
> 6. Can you enable outbound webhooks for app #431, or is there a self-service "Manage App" panel where I set the callback URL + secret?
> 7. Which event types can I subscribe to, selectively? I want `ACTIVITY_ANALYZED` and `CALENDAR_UPDATED`.
> 8. Your cookbook says "activity webhooks are not delivered for Strava activities." If an athlete's rides arrive via Strava, do I get no `ACTIVITY_*` webhook at all? Any event that does fire for Strava-sourced data?
> 9. How do I verify authenticity — the `secret` in the body only, or a signature header? Does it rotate? Retry window / max attempts on non-2xx?
> 10. Does the webhook payload's `athlete_id` match the `athlete.id` from the OAuth token exchange?
>
> Thanks very much — happy to share more detail if useful.
>
> Best, Nick
