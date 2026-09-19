# Freestyle release

P2 repository delivery does not authorize a production migration, Worker
release, TestFlight upload, App Review submission or public release.

## Order

1. Pin the reviewed merged source and read the live Worker and migration ledger.
   Complete the [metadata prerequisites](metadata-release.md): physical rename
   0045 and metadata migration 0053 must precede 0054. Reconcile other pending
   migrations individually; do not apply an unreviewed migration bundle.
2. With owner migration authority, apply `0054_freestyle_sessions.sql`. Existing
   sessions default to `planned`; the new receipt table starts empty. Verify
   both additions and triggers. The existing workout-write fence must be active
   before the attempt-aware iOS start endpoint is used.
3. Deploy the pinned compatible Worker with separate release authority. Verify
   public source identity, then authorized test-account REST/MCP behavior:
   explicit freestyle start persists before a first set; logging uses null slot
   IDs; scheduled workouts remain unchanged; non-capable clients cannot mutate
   hidden live sessions; a redacted discarded row for the previous attempt and prior-set tombstones clear
   old cached attempts; completed history and its sets replay through sync.
   Verify reviewed save, lost-response retry, plan/source conflict and old-attempt
   rejection. MCP unscheduled `log_set` also creates freestyle immediately.
4. Distribute a matching iOS build only after Worker verification. The client
   declares `freestyle` and shows starts only after a live `freestyle_version:1`
   response. Exercise additions and inputs use account-scoped runner checkpoints;
   ordinary outboxes own set/terminal delivery. Test start, add, timers, offline
   recovery, finish and reviewed save on a physical device, including large text
   and VoiceOver. App Review and public release remain separate gates.

## Recovery

Before any freestyle writes, the additive migration leaves existing sessions
planned. Once freestyle rows or save receipts exist, retain a freestyle-capable
Worker and fix forward. A pre-0054 Worker can infer scheduled templates for null
pins and lacks source/attempt save guards. Withholding a new iOS build does not
prevent MCP from writing freestyle after Worker deployment. Do not drop the
kind column, receipts or guard triggers as routine rollback.

Saved workouts remain unscheduled. Saving preserves historical null slot IDs,
advances the session attempt once and commits workout slots, plan version,
audit, snapshot and retry receipt in the same D1 batch. The completed session
keeps its freestyle origin, with the new workout pin supplying its library
association. Source-set IDs bind each edited target to one distinct reviewed cohort. Request
field order and source-ID order are not retry identity.
