# Partner Training — Design

Supporting design for [plan.md](plan.md). The plan owns status and next step.

## What the two people see

1. Nick props up the iPad, links his iPhone as he does today, and opens his
   workout. On the iPad he taps **Train together**. The iPad shows a QR code.
2. Alex opens Tres Fort on their own iPhone, signed in as themselves, and taps
   **Join a Station** (Today, and the runner menu). They scan the code. The iPad
   shows "Alex wants to join" with **Allow** and **Not now**; Nick taps Allow.
3. Alex's phone shows **Your weights** for Nick's workout. Each exercise is
   filled with Alex's own most recent working weight for that exercise, in the
   unit Alex logged it in. An exercise Alex has never logged shows Nick's
   target with a "Check" badge. Sets, reps, rest and supersets come from Nick's
   workout; Alex may change any weight or rep target here, or later in the
   runner as usual.
4. Alex taps **Start**. The workout is saved to Alex's library and opens in
   Alex's normal runner. Both phones now run the same workout independently.
5. The iPad splits into two lanes, one per person: name, exercise, set number,
   weight, and rest remaining. Each phone logs its own sets (manually in P0;
   counted in P1/P2).
6. Either person can finish or leave. Leaving removes their lane; the other
   person's workout continues.

## Key choices

### Who controls what

Each iPhone stays the only controller of its own member's workout, exactly as
in the single-person link (`ipad-workout-station#P2`). The iPad is a shared
display and sensor. It has no API client or outbox for either person, and it
never writes to the host's account on the partner's behalf. Every set reaches
the server from the phone of the person who lifted it, through the existing
LOG SET, correction and Undo paths.

Rejected: the iPad as the controller for both people. It would need a second
signed-in account on one device and a second offline outbox, and it breaks the
rule that only the phone writes.

### How the partner's phone pairs with the iPad

Recommended: **a one-time QR join code, confirmed on the iPad.** The iPad
generates a random 256-bit join secret per invitation and shows it as a QR
code with a short expiry (two minutes) and single use. The partner's phone
proves it holds the secret with the same challenge-response, per-connection
key and sealed, counted messages as today's link
(`StationLink.proof` / `sessionKey` / `seal`), but keyed by the join secret
instead of the account link key. After the proof, the phone sends the member's
display name and the iPad asks the host to allow it. The partner's lane key
lives only in memory and is forgotten when they leave or the session ends.

This needs no server change, no shared group and no deployment. A bystander who
photographs the code still needs the host to tap Allow, and the code dies on
first use.

Alternative: a server-issued pair key for two members of the same group. It
removes the scan, but requires both people to share a group and a new Worker
route and deploy, and it makes the server part of a local, in-room decision.

### How the partner gets the workout and their weights

The host's phone sends its open workout (exercise IDs, order, groups,
sets/reps/duration targets, rest, and the host's weights and units) to the
iPad over the sealed link, and the iPad passes it to the partner's phone.

The partner's phone picks starting weights from the partner's own history:
the most recent working (non-warm-up) set for the same catalog exercise, kept
in its own unit. If none exists, it shows the host's target and unit, marked
"Check". Weights are never converted or scaled from the host's numbers, in line
with the repository rule against extrapolating loads across people or
exercises.

Recommended: **save the partner's copy to their library** as an ordinary
workout with the host's name ("Upper A — with Nick"), so the partner's runner,
rest, supersets, corrections, offline recovery and history all work unchanged,
and they can run it again or archive it. This needs one atomic create of a
workout with its slots; the current `POST /api/workouts` only takes exercise
IDs, so P0 adds that write using the freestyle save path's slot shape.

Alternative: a temporary session that is never saved as a workout. It keeps
the library clean, but needs a second runner path for a session without a
workout.

Same workout is a starting point, not a lock: each runner can still swap, skip
or add sets. The iPad shows whatever each phone reports.

### How the iPad tells the two people apart

This is the open decision.

**Turn-taking (recommended first).** Partners on one bar, rack or bench usually
alternate: one lifts while the other rests or spots. The iPad shows whose set is
next in large type before the set starts; it alternates after each logged set,
and one tap on the name switches it. The counter counts the one person who is
moving and ignores a still partner or spotter. Two people moving at once
holds the count and nobody auto-logs. The finished count goes only to that
person's phone. A wrong name is visible before the set starts, and Undo covers
any miscount.

**Side by side.** Both lift at once with their own equipment, for example
dumbbell curls. Each person claims a lane (left or right) when the session
starts, with a swap control. The iPad tracks each person by position from frame
to frame and counts each lane against that person's armed set. When people
cross, overlap or one leaves the frame, that person's count stops and the set
stays manual. A count is never moved from one person to another.

Not considered: telling people apart by face or appearance. It is a biometric
feature, needs enrollment, and gives little over lanes or turns.

Both modes depend on the counter work in `ipad-workout-station#P1`: today's
live counter stops when a second person appears, and the generic 3D counter
prototype (PR #236) runs one person at a time. Each mode uses the person's own
armed exercise as the counter's hint.

## Privacy and safety

- Camera frames stay on the iPad, as today. Test recording is off while a
  partner is linked, so nobody is recorded by someone else's device.
- The partner's name, workout and weights appear on the shared screen only
  while they are linked, and the iPad keeps none of it afterwards.
- Joining reveals nothing about the partner beyond their display name and the
  workout they choose to run. No group membership, feed visibility or blocking
  rule changes.
- The QR step does not check group membership or blocks; the host's Allow tap
  decides who joins.

## What changes where

- iPad (Station): Train together, QR join, partner confirmation, two-lane
  display; later, turn attribution or lanes for counting.
- iPhone: Join a Station, Your weights sheet, partner copy save; the runner
  link reused for the partner's lane.
- Link protocol: a join-secret-keyed handshake beside the account-key one, a
  workout handoff message, and lane/turn identity on arm and count messages.
- Worker: one atomic create of a workout with slots (P0). No new tables.
