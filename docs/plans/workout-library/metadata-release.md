# Workout metadata release

P1 implements tags and archiving in the repository. Production migration,
Worker deployment and iOS distribution require separate owner authorization;
this implementation does not establish any of those release events.

## Required order

1. Pin the reviewed merged source and verify the live Worker and applied
   migrations. Migration 0045 must already have renamed the physical table to
   `workouts`. Preserve the existing workout-rename release gates; the local
   compatibility test's rewritten legacy schema is a test fixture only.
2. Apply additive migration `0053_workout_metadata.sql` before deploying the
   metadata-capable Worker. Reconcile any intervening unapplied migrations
   separately rather than treating an unqualified migration command as approval.
   This adds default-empty tags, nullable archive timestamps and session-write
   triggers; it does not archive or retag existing workouts.
3. Deploy the reviewed compatible Worker and verify its public health/release
   identity. Verify authorized test-account reads through canonical REST
   and MCP, then a versioned tags/archive/restore round trip. Confirm that stale
   versions conflict, active workouts cannot archive, planned dates become rest,
   completed history retains its names and sets, and archived IDs cannot be
   assigned through REST or MCP. The owner retired legacy clients and the old
   REST vocabulary; do not require a removed alias as a release canary.
4. Only after server verification, distribute the matching iOS build using the
   normal TestFlight release procedure. Check tag filters, archive cancellation,
   explicit restore, trip ordering and runner recovery on a physical device.
   App Review and public release remain separate gates.

Archived rows remain in the canonical plan tree to render completed history.
The Worker rejects attempts to assign them with the permanent not-found error.
The current iOS client uses canonical workout routes and fields.

## Recovery boundary

Before metadata writes, the additive columns contain only their defaults.
After tags or archives exist, do not roll back to a pre-0053 Worker: its
full-plan rebuild and snapshot serializer can lose metadata and restore
archived entries to active status. Retain a metadata-capable Worker and fix
forward, or prepare a separately reviewed rollback that preserves these fields
and assignment fences. Do not drop columns or triggers as a routine rollback.
Withholding the new iOS build does not remove metadata already written by MCP.
