import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, expect, it } from 'vitest';
import catalog from '../ios/TresFort/Station/StationTrackingCatalog.json';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });

it('audits every migrated exercise exactly once, with no retired or invented IDs', async () => {
  const { results } = await env.DB.prepare('SELECT id FROM exercises').all<{ id: string }>();
  const mapped = catalog.groups.flatMap(group => group.exercises);
  expect(new Set(mapped).size).toBe(mapped.length);
  expect([...mapped].sort()).toEqual(results.map(row => row.id).sort());
});

it('requires a declared movement profile or an explicit manual fallback reason', () => {
  expect(catalog.schemaVersion).toBe(1);
  const profiles = new Map(catalog.profiles.map(profile => [profile.id, profile]));
  expect(profiles.size).toBe(catalog.profiles.length);
  for (const group of catalog.groups) {
    expect(group.exercises.length).toBeGreaterThan(0);
    if (group.profile) {
      const profile = profiles.get(group.profile);
      expect(profile, group.profile).toBeDefined();
      expect(profile?.cameraView).toBeTruthy();
      expect(profile?.definition).toBeTruthy();
      expect(profile?.limitation).toBeTruthy();
    } else {
      expect(group.trial).toBeNull();
      expect(group.reason).toBeTruthy();
    }
  }
});

it('maps static holds to seconds while keeping cardio on the manual timer', async () => {
  const { results } = await env.DB.prepare("SELECT id, modality FROM exercises WHERE modality IN ('timed','cardio')")
    .all<{ id: string; modality: string }>();
  for (const row of results) {
    const group = catalog.groups.find(group => group.exercises.includes(row.id));
    const profile = catalog.profiles.find(profile => profile.id === group?.profile);
    if (row.modality === 'timed') expect(profile?.measurement, row.id).toBe('hold');
    else {
      expect(group?.profile, row.id).toBeNull();
      expect(group?.trial, row.id).toBeNull();
    }
  }
});

it('does not enable a trial merely because a related exercise shares a profile', () => {
  const trials: Record<string, string> = {
    squat: 'squat', curl: 'curl', benchPress: 'horizontal_press', plank: 'plank', wallSit: 'wall_sit',
  };
  for (const group of catalog.groups) {
    if (group.trial) expect(group.profile).toBe(trials[group.trial]);
  }
  expect(catalog.groups.find(group => group.exercises.includes('ex_sa_db_bench'))?.trial).toBeNull();
  expect(catalog.groups.find(group => group.exercises.includes('ex_side_plank'))?.trial).toBeNull();
  expect(catalog.groups.find(group => group.exercises.includes('ex_plank'))?.trial).toBe('plank');
});
