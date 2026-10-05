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
    app, and the host confirms on the iPad. A phone signed in as the host's
    own account is refused before confirmation, using an account fingerprint
    keyed by the join secret. Start is offered only after both phones have
    acknowledged storing their lane resume keys; until then the allowed phone
    can fetch its key again. Starting the workout ends joining.
  - The partner's phone receives the host's workout over the sealed link with
    every writable slot field and its supersets or circuits, and opens "Your
    weights": each working slot uses the partner's own most recent working
    weight and unit, else the host's target marked "Check"; warm-up slots keep
    the host's target, marked "Check".
  - Save the partner's copy to their library in one atomic create of a workout
    with full slots through the shared plan writer, with fresh slot and group
    IDs that keep each superset's members, then open their runner. The phone
    picks the workout ID once and retries the same request, which returns the
    existing copy instead of duplicating it; a planless partner's plan is
    created in the same write.
  - Until multi-session days ship, refuse to start when either member already
    has a started (any logged set) or finished strength session that date, and
    say so on the iPad; a planned session, or an opened one with no
    logged set, is replaced.
  - Start in two phases: each phone makes one write that assigns the workout
    to the date, starts that session and records its reviewed starting
    prescriptions, refusing a session that already holds a live set and
    advancing its attempt, then acknowledges to the iPad; dual
    mode begins only after both succeed. Starting the session pins the workout,
    since plan writers already refuse to archive, delete or restore a workout
    that is in progress. Each Start write also checks the plan ID and version
    its phone reviewed: the host's from the handoff, the partner's from the
    create that saved their copy. Try again repeats both sides, and dual mode
    begins only when both succeed in that round; a refusal or Cancel discards
    each side's empty session, and after a changed plan the partner reviews the
    current workout again. Each phone keeps its pending Start, with a session ID
    it generates when the date has no session yet, in its runner checkpoint and
    resolves it itself if the iPad never learned the outcome: it discards on a
    cancelled start, or offers to continue alone or discard if the iPad is
    gone. Continuing alone is final for that lane, and a cancel's discard is
    refused once the session holds a live set. The step sequence is fixed once both have started.
  - The iPad holds the shared step: both phones arm the same exercise and set;
    once both have logged it, the pair rests for that step's handed-off rest
    (or taps Skip rest) before the next step is armed for both.
    Steps are named by host slot ID and set number, which the partner's phone
    maps to its own copy's slots, so duplicate exercises never share an
    acknowledgement. A step is released only after both acknowledgements and
    its rest, so an Undo on either phone rewinds to that set and cancels rest
    while the other lane's set stays logged. Swap, add, reorder and remove are off during
    a dual workout, and every Worker writer that would change, regroup or
    rebuild a slot (including `update_plan` and grouping) refuses a workout in
    an in-progress dual session; a skip applies to both, recorded by the iPad
    and replayed to any lane that missed it, and an Undo of a set in a skipped
    step clears that skip. Each person logs, corrects and
    undoes their own sets by hand.
  - Show two lanes on the iPad (name, weight, reps, logged state). Either person
    can stop; their lane closes for good and leaves the step quorum, so the
    other continues alone. A dropped phone's lane waits for that same phone,
    proven by a per-lane resume key (the host's generated by the host's phone
    on "Train together", the partner's issued by the iPad on Allow) and kept in that phone's Keychain until the lane
    closes; another phone on the host's account cannot take the host's lane.
    The slot map and step sequence persist with each runner checkpoint. A
    dropped phone stays on the shared step it last saw. On every connect and
    reconnect, each phone first sends its lane state for every step from its
    durable checkpoint; the iPad adopts it and recomputes the shared step
    against its own record of released steps and the running rest. A queued
    set counts as logged; if the Worker later rejects it, that phone reports
    it like an Undo and the pair rewinds to it. The other member can choose "Continue
    alone".
    If the iPad is lost, each phone continues as a normal solo workout.
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
- No new tables are planned; P0 adds a dual-session marker column on
  `sessions`. P0 adds one atomic "create workout with slots" write, because `POST /api/workouts` takes exercise IDs without
  prescriptions; its slot payload carries every writable slot field, including
  supersets, warm-ups, rep ranges, RPE, cues and progression.
- Out of scope: more than two people, partners without the app, joining after
  the start, per-person exercise differences, and a shared "trained together"
  record in the group feed.
