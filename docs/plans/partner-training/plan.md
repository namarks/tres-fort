# Partner Training on One iPad

Slug: partner-training · Status: planned · Updated: 2026-10-05 · Theme: gym-floor

## Goal

Let two members train the same workout together in front of one iPad Station.
Each signs in on their own iPhone, runs the workout in their own runner with
their own weights, and logs to their own account. The iPad shows both people
and, once counting is validated, counts each person's sets for their own phone.

Done means:

- a partner joins the session on the iPad from their own Tres Fort app, without
  sharing an account, a group or a password with the host;
- the partner gets the host's workout with their own weights already filled in,
  can change any weight before or during the session, and keeps their own unit;
- each phone logs only its own member's sets through the existing runner paths,
  and nothing a partner does is ever written to the host's account or the iPad;
- the iPad shows both people's current exercise, set, weight and rest; and
- in each counting mode that ships, a count is attributed to the right person
  or not used at all, with Undo and manual logging still available.

The design and the choices behind each phase are in [spec.md](spec.md).

## Phases

- [ ] **P0 — Join, shared display and manual logging**
  - On the iPad, the linked host starts "Train together"; the iPad shows a
    one-time join code as a QR code. The partner scans it in their own app, and
    the iPad asks for confirmation with the partner's display name.
  - The partner's phone receives the host's current workout over the sealed
    link and opens a "Your weights" sheet: each exercise uses the partner's own
    most recent working weight and unit, else the host's target marked "Check".
  - Starting saves the partner's copy of the workout to their own library in one
    atomic write (slots, groups, rest and units), then opens their normal runner.
  - The iPad shows two lanes, one per person; neither lane counts reps yet. Each
    phone logs manually, and either person can leave without ending the other's
    workout.
  - Keep the iPad free of partner data after the session ends; disable test
    recording while a partner is linked.
- [ ] **P1 — Count the person whose turn it is**
  - Show whose set is next in large type on the iPad; default to alternating
    after each logged set; one tap on the name switches it.
  - Replace the current "more than one person, stop counting" rule with choosing
    the one person who is moving, so a resting partner or spotter in frame does
    not block the count. Two people moving at once holds the count; nobody
    auto-logs.
  - Send the finished count only to the phone whose turn it is, using that
    phone's armed exercise as the counter's hint. Undo and manual logging work
    as in single-person Station mode.
- [ ] **P2 — Count two people side by side**
  - Assign each person a lane (left or right of the iPad) when the session
    starts, with a swap control, and track each person by position between
    frames.
  - Count each lane independently against that person's armed set. When the
    two people cross, overlap or one leaves the frame, stop that person's count
    and leave the set manual; never move a count from one person to the other.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | blocked_by | plan:ipad-workout-station#P2 | The partner link reuses the single-member iPhone–iPad link, which still needs its paired-device trial. |
| P1 | blocked_by | plan:ipad-workout-station#P1 | Counting a chosen person needs the counter chosen and measured on the mounted iPad first. |

## Next step

**Now (@owner):** Choose whether turn-taking (P1) or side-by-side counting (P2)
comes first, and activate this plan when it should start. Implementation also
waits for the Station link trial (`ipad-workout-station#P2`).

## Notes / open questions

- Open owner choice: turn-taking first (recommended; it fits shared equipment
  and spotting, and only has to ignore a second person) or side-by-side first
  (both lift at once with their own equipment; needs two-person tracking).
  Swap P1 and P2 if the owner chooses side by side.
- Defaults taken in the spec, each open to the owner: QR join with on-iPad
  confirmation rather than a server-issued key for group members; the partner's
  copy stays in their library (archivable) rather than a temporary session;
  each phone stays the only controller of its own workout.
- No new backend data model is planned. P0 likely needs one atomic "create
  workout with slots" write, because `POST /api/workouts` takes exercise IDs
  without prescriptions; it would reuse the freestyle save path's slot shape.
- Out of scope: more than two people, partners without the app, a shared
  "trained together" record in the group feed, and a partner who is the same
  account as the host.
