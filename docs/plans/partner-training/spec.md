# Partner Training — Design

Supporting design for [plan.md](plan.md). The plan owns status and next step.

## Owner decisions (2026-10-05)

- Start with **side by side**: both people do the same set at the same time and
  move through the workout together. Turn-taking (one lifts, the other rests or
  spots) is a later mode; both must eventually be supported.
- A dual workout is **started as a dual workout**. Nobody can join once the
  first set has begun. This removes mid-workout join cases by design.

## What the two people see

1. Nick props up the iPad and links his iPhone as he does today. Before logging
   any set, he picks a workout and taps **Train together** on the iPad. The iPad
   shows a QR code.
2. Alex opens Tres Fort on their own iPhone, signed in as themselves, and taps
   **Join a Station** on Today. They scan the code. The iPad shows "Alex wants
   to join" with **Allow** and **Not now**; Nick taps Allow.
3. Alex's phone shows **Your weights** for Nick's workout. Each exercise is
   filled with Alex's own most recent working weight for that exercise, in the
   unit Alex logged it in. An exercise Alex has never logged, and any warm-up,
   shows Nick's target with a "Check" badge. Alex may change any weight or rep target.
4. Each person stands in their spot; the iPad shows who is on the left and who
   is on the right, with a swap button. Either person taps **Start together**
   once both are ready. From this point no one else can join.
5. The iPad shows one exercise and set for both, split into two lanes: name,
   weight and reps for each person. Both do the set, each phone logs its own
   member's set (by hand in P0, from the iPad's count in P1), and rest starts
   once both have logged. The next set starts for both together.
6. Either person can stop. Their lane closes for the rest of the workout, the
   iPad stops waiting for them, and the other person continues alone; a closed
   lane is never reopened.

## Key choices

### Who controls what

Each iPhone stays the only writer for its own member, as in the single-person
link (`ipad-workout-station#P2`): every set reaches the server from the phone of
the person who lifted it, through the existing LOG SET, correction and Undo
paths. The iPad has no API client or outbox and never writes to the host's
account on the partner's behalf.

Moving through the workout together adds one shared piece of state: the current
step (exercise, set, and whether the pair is resting). The iPad holds it, since
both phones connect to it. A phone arms only the current step. The step is
derived from each lane's acknowledged sets, never advanced by a timer or a
single message: it is the earliest set that is not yet logged or skipped in
both lanes, and rest runs only while both lanes have that set logged.

A step is named by the host's slot ID and the set number, never by exercise:
a workout can hold the same exercise twice (a warm-up squat and a working
squat), and the partner's copy has its own slot IDs. When the partner's phone
saves its copy, it keeps a map from each host slot ID to its own slot ID.
Every arm, log, skip and Undo message carries the host slot ID and set number;
the partner's phone translates through the map, so one slot's acknowledgement
can never satisfy another.

Undo therefore rewinds without a special case. When a phone's Undo deletes its
set, that lane reports the set as no longer logged; the step returns to that
set, rest stops, and only that phone re-arms it. The other lane's logged set
stays logged and acknowledged, and that lane shows "waiting for Alex" until the
set is logged again. A correction that edits weight or reps does not move the
step.

Stopping removes a lane from the quorum. When a member stops, their lane
closes for the rest of the workout and the shared step then follows the
remaining lane alone, which continues as a single-person Station workout from
its own next unlogged set. A closed lane never reopens. If one phone's link
drops, its lane holds and the iPad waits for that same phone to reconnect,
proven by the lane's resume key (see pairing below); a different person or
phone cannot take the lane. The other member can tap
"Continue alone" at any time, which closes the dropped lane as if that member
had stopped. If the iPad itself is lost, both phones carry on alone from their
own last logged set, as normal workouts.

Rejected: the iPad logging for both people. It would need a second signed-in
account on one device and a second offline outbox, and it breaks the rule that
only the phone writes.

### One session per date

Today a member can hold only one strength session per date
(`ux_session_user_date`; `workouts-and-multi-session#P1` lifts that). Until
then, a dual workout uses each member's session for that date. A planned but
unstarted session is replaced, as the existing "train a different day"
choice does. If either member has already started a strength session that
date (it has a logged set) or finished one, the iPad says so before the
partner is allowed in, and the dual workout cannot start. Once multi-session
days ship, the dual workout becomes an additional session instead.

### Starting together

The handoff names the host's workout as it was reviewed: plan ID, plan version
and the workout's slot list. The host's phone checks that version again when
it assigns the date on Start. If a coach or another device changed the plan
since the handoff, the host's assignment is refused, the iPad sends the
partner the current workout, and the partner reviews "Your weights" again
before Start. Once both have started, the step sequence is fixed from that
handoff; a later plan edit applies to future workouts, not to this one.

Each phone writes its own date assignment, so "Start together" cannot be one
atomic write across two accounts. It is two-phase instead. On Start, each
phone saves its copy if needed and assigns the workout to that date through the
existing `set_planned_session` path with its observed `expected_attempt`, then
reports success or failure to the iPad. Dual mode, and the first armed set,
begin only after both phones have acknowledged. An assignment with no logged
set is not a started session, so a failure on one side leaves nothing that
blocks a retry: the iPad shows which phone failed and offers **Try again** or
**Cancel**. Trying again repeats only the failed side; an identical assignment
is already idempotent. Cancel ends the dual workout before any set; each
member keeps an ordinary planned session for that date that they can run alone
or change as usual.

### Same structure, personal loads

Both people run the same exercises in the same order with the same sets and
rest. During a dual workout, swap, add, reorder and remove are unavailable;
skipping a set or exercise skips it for both. Each person keeps their own
weight, unit and reps, and either can correct or undo their own set. Skipping
an exercise for one person only, or splitting into different exercises, is out
of scope until real use shows it is needed.

### How the partner's phone pairs with the iPad

**A one-time QR join code, confirmed on the iPad.** The iPad generates a random
256-bit join secret for one invitation and shows it as a QR code. It is valid
for two minutes, for one phone, and only until the dual workout starts. The
partner's phone proves it holds the secret with the same challenge-response,
per-connection key and sealed, counted messages as today's link
(`StationLink.proof` / `sessionKey` / `seal`), keyed by the join secret instead
of the account link key. After the proof, the phone sends the member's display
name and an account fingerprint: an HMAC of its account ID under the join
secret, so the iPad learns whether two phones share an account without learning
the partner's ID. The iPad computes the same fingerprint for the host account
it is signed in as; if they match, it refuses the phone ("This phone is signed
in as Nick") before offering Allow, because two lanes on one account would
write both people's sets into one session. The iPad then asks the host to allow
the partner. On Allow, the iPad sends the partner's phone, over the sealed
connection, a fresh random 256-bit resume key for this lane. The join secret is
then dead. If the partner's connection drops, the phone reconnects with the
same challenge-response keyed by the resume key, so only the phone that was
allowed can take the lane back; a device that copied the QR code has no
resume key. The host's phone reconnects with the account link key as today.
The partner's phone stores its resume key in the Keychain, scoped to its
account and this dual workout, so it survives the app being closed or evicted
and the phone can reclaim its lane after restoring its runner. The key is
deleted when the lane closes, the dual workout ends, or the member signs out.
The iPad holds its copy only in memory; if the iPad app is closed, the dual
workout ends and both phones continue alone.

This needs no server change, no shared group and no deployment. A bystander who
photographs the code still needs the host to tap Allow, and the code is dead
once used or once the workout starts.

Alternative: a server-issued pair key for two members of the same group. It
removes the scan, but requires a shared group, a new Worker route and a deploy,
and it makes the server part of an in-room decision.

### How the partner gets the workout and their weights

The host's phone sends its workout to the iPad over the sealed link, and the
iPad passes it to the partner's phone. The handoff carries every writable
prescription field the plan tree keeps for a slot, the same fields
`serializePlanSnapshot` records: order, exercise, sets, rep range, duration,
weight and unit, RPE, rest, warm-up flag, cues, progression, and superset or
circuit membership with group rest and transition times.

The partner's phone picks starting weights for working slots from the
partner's own history: the most recent working (non-warm-up) set for the same
catalog exercise, kept in its own unit. If none exists, it shows the host's
target and unit, marked "Check". Warm-up slots (`is_warmup`) are never filled
from working-set history, which could turn a 45 lb ramp-up into a 225 lb set;
they keep the host's target and unit, marked "Check". Weights are never
converted or scaled from the host's numbers, in line with the repository rule
against extrapolating loads across people or exercises.

The handoff is a template, not identities. The partner's copy gets fresh slot
IDs and fresh group IDs, one new group ID per host group, so every superset or
circuit keeps its members and order. Reusing the host's IDs would collide with
the host's workout and with the partner's earlier copies, because a group ID
must be unique across a member's whole plan (`validatePlanExerciseGroups`).

**The partner's copy is saved to their library** as an ordinary workout named
after the host's ("Upper A — with Nick"), so their runner, rest, supersets,
corrections, offline recovery and history work unchanged, and they can run it
again or archive it. The current `POST /api/workouts` takes only exercise IDs,
so P0 adds one atomic create of a workout with full slots, through the shared
plan writer (version, audit, snapshot). Its slot payload is the full writable
slot above, not the freestyle save shape, which has no groups, warm-ups, rep
ranges, RPE, cues or progression.

The create is idempotent. As in the freestyle save, the phone generates the
new `workout_id` (and the fresh slot and group IDs) once, keeps them with the
pending start, and sends the same request on every retry. If that workout
already exists with the same content, the Worker returns it and the current
plan version as a success instead of creating a second copy; a different
payload under the same ID is rejected. A lost response therefore never
duplicates the library entry or leaves the phone unable to open its copy.

A partner who has no active plan yet (an account that skipped setup) still
gets a copy: the same create makes their plan first, in the same batch, and
returns it. Nothing about the dual workout requires the partner to have set up
training before.

Alternative: a temporary session that is never saved as a workout. It keeps
the library clean, but needs a second runner path for a session without a
workout.

### How the iPad tells the two people apart

**Side by side (first).** Each person is assigned a lane, left or right of the
iPad, before the workout starts. The iPad tracks two people and keeps each one's
identity by position from frame to frame, counting each lane against that
person's armed set and using the shared exercise as the counter's hint. When
people cross, overlap or one leaves the frame, that person's count stops and
their set stays manual. A count is never moved from one person to the other,
and a third person in frame holds counting for both.

**Turn-taking (later).** One person lifts while the other rests or spots. The
iPad shows whose set is next in large type before the set starts and alternates
after each logged set; one tap on the name switches it. The counter counts the
one person moving and ignores a still partner. Two people moving at once holds
the count. The step advances after both have taken their turn.

Not considered: telling people apart by face or appearance. It is a biometric
feature, needs enrollment, and gives little over lanes or turns.

Both modes depend on the counter work in `ipad-workout-station#P1`: today's
live counter stops when a second person appears, and the generic 3D counter
prototype (PR #236) handles one person at a time.

## Privacy and safety

- Camera frames stay on the iPad, as today. Test recording is off during a dual
  workout, so nobody is recorded by someone else's device.
- The partner's name, workout and weights appear on the shared screen only
  during the dual workout, and the iPad keeps none of it afterwards.
- Joining reveals nothing about the partner beyond their display name and the
  weights they choose to show. No group membership, feed visibility or blocking
  rule changes.
- The QR step does not check group membership or blocks; the host's Allow tap
  decides who joins.

## What changes where

- iPad (Station): Train together, QR join, partner confirmation, lane
  assignment, shared step, two-lane display; later, per-lane counting and
  turns.
- iPhone: Join a Station, Your weights sheet, partner copy save, a dual mode in
  the runner that follows the shared step and hides structural edits.
- Link protocol: a join-secret-keyed handshake beside the account-key one, a
  workout handoff message, the shared step, and lane identity on arm and count
  messages.
- Worker: one idempotent, atomic create of a workout with full slots, which
  also creates the member's plan when they have none (P0). No new tables.
