import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { acceptStarterWorkout, addWorkoutAtVersion, createPlan, deleteUserAccount, deleteWorkout, ensureOwnerUser, exportUserData, getPlanTree, getStarterWorkouts, getTrainingProfile, saveTrainingProfile, upsertUser } from '../src/db';
import { handleMcp } from '../src/mcp/server';
import { parseTrainingProfile, starterWorkouts, type TrainingProfile } from '../src/trainingProfile';

const profile: TrainingProfile = { goal: 'general_fitness', activities: ['weightlifting', 'running', 'swimming'],
  activity_context: 'Two easy runs and a weekend swim', experience: 'new', strength_days: 2,
  session_minutes: 30, equipment: 'gym', avoid: [], baselines: [] };
beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
const member = () => upsertUser(env.DB, crypto.randomUUID(), null, 'Synthetic member');

describe('private training profile and first workout', () => {
  it('saves multisport intent without creating a plan and retries identical content without a new version', async () => {
    const u = await member();
    expect(await getTrainingProfile(env.DB, u.id)).toEqual({ profile: null, version: 0, updated_at: null });
    const saved = await saveTrainingProfile(env.DB, u.id, profile, 0);
    expect(saved).toMatchObject({ version: 1, profile: { activities: ['running', 'swimming', 'weightlifting'] } });
    expect(await saveTrainingProfile(env.DB, u.id, profile, 0)).toEqual(saved);
    expect(await saveTrainingProfile(env.DB, u.id, { ...profile, strength_days: 3 }, 0)).toEqual({ conflict: true });
    expect(await getPlanTree(env.DB, u.id)).toBeNull();
  });

  it('validates unknown, duplicate, oversized and incorrectly typed inputs before storing anything', async () => {
    const u = await member();
    for (const patch of [{ activities: ['running', 'running'] }, { activities: ['triathlon'] }, { strength_days: true },
      { session_minutes: -1 }, { activity_context: 'x'.repeat(301) }, { avoid: ['diagnosis'] },
      { baselines: [{ exercise_id: 'ex_bench', weight: '50', unit: 'kg', reps: 8, effort: 'easy', performed_at: Date.now() }] }, { user_id: u.id }]) {
      expect(await saveTrainingProfile(env.DB, u.id, { ...profile, ...patch }, 0)).toEqual({ error: 'invalid_fields' });
    }
    expect((await getTrainingProfile(env.DB, u.id)).version).toBe(0);
  });

  it('keeps working-set provenance and never derives a different exercise load', async () => {
    const p = { ...profile, baselines: [{ exercise_id: 'ex_bench', weight: 50, unit: 'kg' as const,
      reps: 8, effort: 'moderate' as const, performed_at: Date.now() - 86400000 }] };
    expect(parseTrainingProfile(p)?.baselines).toEqual(p.baselines);
    const u = await member();
    await saveTrainingProfile(env.DB, u.id, p, 0);
    await acceptStarterWorkout(env.DB, u.id, 'gym-v1', 1);
    const tree = await getPlanTree(env.DB, u.id);
    expect(tree?.workouts[0]?.exercises.every(e => e.target_weight === 0)).toBe(true);
    expect(tree?.workouts[0]?.exercises.every(e => e.cues?.includes('Choose a comfortable load'))).toBe(true);
  });

  it('filters equipment and exclusions, and admits that other sports are not automatically scheduled', () => {
    const options = starterWorkouts({ ...profile, equipment: 'bodyweight', avoid: ['push'] });
    expect(options.map(s => s.id)).toEqual(['bodyweight-v1']);
    expect(options[0]?.exercises.map(e => e.exercise_id)).toEqual(['ex_bw_squat', 'ex_bird_dog']);
    expect(options[0]?.explanation).toContain('does not schedule');
    expect(starterWorkouts({ ...profile, avoid: ['squat', 'hinge', 'push', 'pull', 'core'] })).toEqual([]);
  });

  it('concurrent acceptance creates exactly one complete workout, version, receipt and audit', async () => {
    const u = await member();
    await saveTrainingProfile(env.DB, u.id, profile, 0);
    const [first, retry] = await Promise.all([acceptStarterWorkout(env.DB, u.id, 'gym-v1', 1), acceptStarterWorkout(env.DB, u.id, 'gym-v1', 1)]);
    expect(first).toEqual(retry);
    expect(first).toMatchObject({ acknowledged: true, version: 2 });
    const tree = await getPlanTree(env.DB, u.id);
    expect(tree?.workouts).toHaveLength(1);
    expect(tree?.workouts[0]?.exercises).toHaveLength(4);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM audit_log WHERE user_id=? AND tool='accept_starter_workout'").bind(u.id).first('n')).toBe(1);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM plan_snapshots WHERE user_id=? AND version=2').bind(u.id).first('n')).toBe(1);
    expect(await acceptStarterWorkout(env.DB, u.id, 'gym-v1', 1)).toEqual(first);
    expect(await acceptStarterWorkout(env.DB, u.id, 'bodyweight-v1', 1)).toEqual({ error: 'starter_already_accepted' });
    // Even an emptied library must not offer a new acceptance that can only conflict.
    expect(await deleteWorkout(env.DB, u.id, tree!.workouts[0]!.id, tree!.version)).toMatchObject({ ok: true });
    expect((await getStarterWorkouts(env.DB, u.id)).can_accept).toBe(false);
  });

  it('does not overwrite a manual/coach library, or accept a preview from an older profile', async () => {
    const u = await member();
    await saveTrainingProfile(env.DB, u.id, profile, 0);
    const plan = await createPlan(env.DB, u.id, 'Coach plan');
    await addWorkoutAtVersion(env.DB, u.id, plan, 'Existing workout', null, 0);
    const before = await getPlanTree(env.DB, u.id);
    expect(await acceptStarterWorkout(env.DB, u.id, 'gym-v1', 1)).toEqual({ error: 'training_changed' });
    expect(await getPlanTree(env.DB, u.id)).toEqual(before);
    await saveTrainingProfile(env.DB, u.id, { ...profile, avoid: ['push'] }, 1);
    expect(await acceptStarterWorkout(env.DB, u.id, 'gym-v1', 1)).toEqual({ error: 'profile_changed' });
  });

  it('rolls the workout, slots, receipt and audit back on any failed slot insert', async () => {
    const u = await member();
    await saveTrainingProfile(env.DB, u.id, profile, 0);
    await env.DB.prepare("CREATE TRIGGER fail_starter_slot BEFORE INSERT ON template_exercises WHEN NEW.exercise_id='ex_db_rdl' BEGIN SELECT RAISE(ABORT, 'synthetic_failure'); END").run();
    await expect(acceptStarterWorkout(env.DB, u.id, 'gym-v1', 1)).rejects.toThrow('synthetic_failure');
    expect((await getPlanTree(env.DB, u.id))?.workouts).toEqual([]);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM starter_workout_receipts WHERE user_id=?').bind(u.id).first('n')).toBe(0);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM audit_log WHERE user_id=? AND tool='accept_starter_workout'").bind(u.id).first('n')).toBe(0);
  });

  it('isolates REST and portable export by caller, and survives plan replacement', async () => {
    const a = await member(), b = await member();
    const jwt = await issueAppJwt(a.id, env.APP_JWT_SECRET);
    const res = await SELF.fetch('https://test/api/me/training-profile', { method: 'PUT', headers: {
      Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json',
    }, body: JSON.stringify({ profile, expected_version: 0 }) });
    expect(res.status).toBe(200);
    expect(res.headers.get('Cache-Control')).toBe('no-store');
    await createPlan(env.DB, a.id, 'Replacement');
    expect((await getTrainingProfile(env.DB, a.id)).profile?.activity_context).toBe(profile.activity_context);
    expect(await exportUserData(env.DB, a.id)).toMatchObject({ training: { training_profile: { version: 1 } } });
    expect(await exportUserData(env.DB, b.id)).toMatchObject({ training: { training_profile: null } });
    const unauthenticated = await SELF.fetch('https://test/api/me/training-profile');
    expect(unauthenticated.status).toBe(401);
  });

  it('exposes the authenticated member profile to the coach even before a plan exists', async () => {
    const u = await member(), other = await member();
    await saveTrainingProfile(env.DB, u.id, profile, 0);
    const call = async (userId: string, method: string, params: Record<string, unknown>) => {
      const response = await handleMcp({ jsonrpc: '2.0', id: 1, method, params }, env, userId);
      return JSON.parse(JSON.stringify(response.json)) as { result: { content?: { text: string }[]; contents?: { text: string }[] } };
    };
    const plan = await call(u.id, 'tools/call', { name: 'get_current_plan', arguments: {} });
    expect(JSON.parse(plan.result.content?.[0]?.text ?? '{}')).toMatchObject({
      plan: null, training_profile: { profile: { activity_context: profile.activity_context } },
    });
    const brief = await call(u.id, 'resources/read', { uri: 'coach://state/current' });
    expect(brief.result.contents?.[0]?.text).toContain('weekend swim');
    const otherBrief = await call(other.id, 'resources/read', { uri: 'coach://state/current' });
    expect(otherBrief.result.contents?.[0]?.text).not.toContain('weekend swim');
  });

  it.each(['member', 'owner'])('permanent deletion removes the %s profile and acceptance receipt', async kind => {
    const user = kind === 'owner' ? await ensureOwnerUser(env.DB, undefined) : await member();
    if (!user) throw new Error('Synthetic user was not created');
    const userId = user.id;
    await saveTrainingProfile(env.DB, userId, profile, 0);
    await acceptStarterWorkout(env.DB, userId, 'gym-v1', 1);
    await deleteUserAccount(env.DB, userId, undefined, crypto.randomUUID());
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM training_profiles WHERE user_id=?').bind(userId).first('n')).toBe(0);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM starter_workout_receipts WHERE user_id=?').bind(userId).first('n')).toBe(0);
  });
});
