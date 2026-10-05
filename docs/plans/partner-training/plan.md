# Partner Training on One iPad

Slug: partner-training · Status: planned · Updated: 2026-10-05 · Theme: gym-floor

## Goal

Let two members train the same workout together in front of one iPad Station.
Each signs in on their own iPhone and logs to their own account with their own
weights, while the pair moves through the workout set by set together. The iPad
shows both people and, once counting is validated, counts each person's sets
for their own phone.

Done means:

- a partner joins on the iPad from their own Tres Fort app, before the first
  set, without sharing an account, a group or a password with the host; nobody
  can join once the dual workout has started;
- the partner gets the host's workout, with every slot and superset setting
  intact and their own weights already filled in, and can change any weight;
- both people stay on the same exercise and set, and rest and the next set
  start for both together;
- each phone logs only its own member's sets through the existing runner paths,
  and nothing a partner does is written to the host's account or the iPad; and
- in each counting mode that ships, a count is attributed to the right person
  or not used at all, with Undo and manual logging still available.

The design and the choices behind each phase are in [spec.md](spec.md).

## Phases

- [ ] **P0 — Start a dual workout and move through it together**
  - Before any set is logged, the linked host taps "Train together" on the iPad;
    the iPad shows a one-time QR join code. The partner scans it in their own
    app, and the host confirms on the iPad. Starting the workout ends joining.
  - The partner's phone receives the host's workout over the sealed link with
    every writable slot field and its supersets or circuits, and opens "Your
    weights": each exercise uses the partner's own most recent working weight
    and unit, else the host's target marked "Check".
  - Save the partner's copy to their library in one atomic create of a workout
    with full slots through the shared plan writer, with fresh slot and group
    IDs that keep each superset's members, then open their runner.
  - Until multi-session days ship, refuse to start when either member already
    has a started or finished strength session that date, and say so on the
    iPad; an unstarted planned session is replaced as today.
  - The iPad holds the shared step: both phones arm the same exercise and set,
    rest starts once both have logged it, and the next set starts for both.
    The step is derived from both lanes' acknowledged sets, so an Undo on
    either phone rewinds it to that set and stops rest while the other lane's
    set stays logged.
    Swap, add, reorder and remove are off during a dual workout; a skip applies
    to both. Each person logs, corrects and undoes their own sets by hand.
  - Show two lanes on the iPad (name, weight, reps, logged state). Either person
    can stop; their lane closes for good and the other continues alone. If the
    iPad link is lost, each phone continues as a normal solo workout.
  - Keep the iPad free of partner data afterwards; disable test recording during
    a dual workout.
- [ ] **P1 — Count two people side by side**
  - Assign each person a lane (left or right of the iPad) before the start, with
    a swap control, and track each person by position between frames.
  - Count each lane against that person's armed set, with Undo and manual
    logging as in single-person Station mode. When people cross, overlap or one
    leaves the frame, stop that person's count and leave the set manual; never
    move a count from one person to the other. A third person holds both.
- [ ] **P2 — Add turn-taking**
  - Offer turn-taking as a dual-workout mode chosen at the start: the iPad shows
    whose set is next, alternates after each logged set, and switches on a tap;
    the step advances after both have taken their turn.
  - Count only the person whose turn it is and ignore a still partner or
    spotter; two people moving at once holds the count.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | blocked_by | plan:ipad-workout-station#P2 | The partner link reuses the single-member iPhone–iPad link, which still needs its paired-device trial. |
| P0 | coordinates_with | plan:workouts-and-multi-session#P1 | One strength session per member per date limits a dual workout to members who have not trained yet that day, until ordered sessions per date ship. |
| P1 | blocked_by | plan:ipad-workout-station#P1 | Counting two people needs the counter chosen and measured on the mounted iPad first. |
| P2 | blocked_by | plan:ipad-workout-station#P1 | Counting the person whose turn it is needs the same validated counter. |

## Next step

**Now (@owner):** Activate this plan when it should start. The owner chose
side by side first and dual-start-only on 2026-10-05. P0 implementation waits
for the Station link trial (`ipad-workout-station#P2`).

## Notes / open questions

- Owner decisions (2026-10-05): side by side before turn-taking, with both
  modes supported eventually; a dual workout must be started as one, so nobody
  joins mid-workout.
- Defaults taken in the spec, each open to the owner: QR join with on-iPad
  confirmation rather than a server-issued key for group members; the partner's
  copy stays in their library (archivable) rather than a temporary session;
  structural edits are off during a dual workout and skips apply to both.
- No new tables are planned. P0 adds one atomic "create workout with slots"
  write, because `POST /api/workouts` takes exercise IDs without
  prescriptions; its slot payload carries every writable slot field, including
  supersets, warm-ups, rep ranges, RPE, cues and progression.
- Out of scope: more than two people, partners without the app, joining after
  the start, per-person exercise differences, and a shared "trained together"
  record in the group feed.
