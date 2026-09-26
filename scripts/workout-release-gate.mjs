// Remote migration and deployment remain separately authorized operations.
console.error(`Use the reviewed release procedures in
  docs/plans/workouts-and-multi-session/rollout.md
and the runbook for each pending migration. The canonical Worker requires the
migrated workout schema. The combined migration-before-deploy release and
unqualified remote migration remain disabled pending release-specific approval.
No remote command was executed.`);
process.exitCode = 1;
