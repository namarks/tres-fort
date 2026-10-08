# Partner setup acceptance and release boundary

P0 adds manual training together: a host iPhone, a partner iPhone with a different
account, and a host iPad running Station. No camera counting or test recording is
enabled in a partner workout. No production change or client distribution is
implied by repository review or merge.

## Automated verification

- `npm run typecheck` and `npm test`: full backend regression coverage, including
  real-D1 migration 0056 and the atomic partner copy, Start and cancellation paths.
- `PartnerTrainingTests`: invitation expiry/fingerprints, fresh slot/group IDs,
  full prescription copying and own-history load/unit selection; shared-step
  quorum, rest, Undo, reconnect, closed lanes and checkpoint compare-and-swap.
- Partner cases in `SetOutboxTests`: a successful Start is durable before Station
  is notified, so relaunch before the first shared state recovers offline. The
  ordinary durable outbox keeps each set's account/session/attempt and shared
  set number; only shared state enables a log, and cold unverified state and
  account changes cannot authorize writes.
- `StationLinkTests` and `RunnerRecoveryTests`: existing encrypted transport and
  live/certified-cache recovery behavior.
- `StationPrivacyTests`: partner setup/training keeps Station awake after the
  camera stops, and closing Station restores the previous idle-timer setting.

## Required physical trial

Use disposable test accounts and confirm each account's history independently.
All rows below must pass before treating P0 as accepted. For the public
manual candidate, the pair/start and recovery rows establish the required
host-phone link behavior. The single-member camera logging trial
(`ipad-workout-station#P2`) remains a separate beta acceptance gate; the public
candidate disables camera messages and makes no counting claim. Record actual device models, OS versions,
client build, Worker release SHA, and observed results; no physical trial has been
performed by this implementation session.

| Case | Expected result |
|---|---|
| Pair and start | Host opens an empty workout on iPhone, links Station, then chooses Train together on iPad. Partner scans, host allows, partner reviews weights. Both Start ACKs precede logging. |
| Same account and spent QR | Another host-account phone is refused. Expired QR cannot invite a new member; a spent QR cannot take either lane. No member joins mid-workout. |
| Copy and units | Include duplicate movements, warm-ups, a circuit, reps/RPE/cues/progression, timed work and kg loads. Partner gets fresh IDs and their own working weights/units; fallback targets say Check. Retrying creates one copy. |
| Start failure | Change either reviewed plan or log a set before Start. The pair does not begin. Cancel or leaving during Start ends setup; late ACKs cannot release the pair. Cancel settles each empty start, including a Start whose response was lost, without removing logged work. |
| Shared progress | One phone logs: the pair waits. The second logs: one shared rest begins. Skip rest advances both. Skip set applies to both and preserves physical set numbers. |
| Auto-Lock | With a short iPad Auto-Lock interval, leave the iPad untouched during setup and several sets/rests. Station stays awake. Closing partner mode restores normal Auto-Lock; returning from background keeps an open Station awake again. |
| Undo and rejected upload | Undo during rest and after advancing, then reconnect. The pair rewinds, the other log stays, and already elapsed rests are not replayed. A rejected queued set reopens its step. |
| Drop and relaunch | Disable one phone's local connection; the iPad waits. Relaunch that phone before and after storing its lane key, and immediately after its Start ACK but before shared state arrives. Its checkpoint and complete lane snapshot recover the same lane; a committed Start can recover without internet. |
| Continue alone | Lose the iPad or leave a lane, including without internet after a successful start. Each phone keeps its own logs/outbox and can proceed solo. Reconnect must not reopen the closed lane. |
| Account and privacy boundary | Sign out, switch accounts, delete the account, and close Station. Old views cannot log; lane keys are removed; iPad clears all partner names, targets and invitations. |

## Release order

1. Nick merges only after the configured exact-head Codex review and all required
   checks pass. P0 remains open pending physical acceptance.
2. Confirm the deployed Worker supports the candidate. Migration 0056 and the
   matching Worker were delivered with [build 49](../app-store-submission/release-49.md);
   do not reapply that migration. Any further production change requires
   separate authority.
3. With separate distribution authority, build and distribute the matching iOS
   client. Run the physical trial with that exact backend/client pair.
4. Camera side-by-side and turn-taking work remain P1 and P2.

For a rollback, retire or continue affected lanes before reverting a Worker that
is unaware of their markers. Retain the additive column and audit receipts until
an explicitly reviewed rollback procedure proves them unnecessary.
