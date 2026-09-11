import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { createGroup, dedupeHealthKitAgainstIntervals, discardSession, getGroupActivitySeries,
  getGroupFeed, getGroupStats, getProjectedCalendar, getRecentActivities, patchSession,
  syncExternalActivities, upsertHealthKitActivity, type HealthKitActivityInput } from '../src/db';
import { issueAppJwt } from '../src/auth';
import { runWorkoutWriteBatch } from '../src/workout-write-fence';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });

const start = Date.now() - 3_600_000;
const date = new Date(start).toISOString().slice(0, 10);
const duration = 1800;
async function seed(status = 'completed', startMs: number | null = start, endMs: number | null = start + duration * 1000, civilDate = date) {
  const userId = crypto.randomUUID(), planId = crypto.randomUUID(), sessionId = crypto.randomUUID();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO users(id,apple_sub,created_at,timezone,share_health_activities) VALUES (?1,?1,1,'UTC',1)").bind(userId),
    env.DB.prepare("INSERT INTO plans(id,user_id,name,status,version,created_at,updated_at) VALUES (?1,?2,'test','active',1,1,1)").bind(planId,userId),
  ]);
  await runWorkoutWriteBatch(env.DB, [env.DB.prepare(`INSERT INTO sessions
    (id,user_id,plan_id,date,status,started_at,completed_at,created_at,updated_at)
    VALUES (?1,?2,?3,?4,?5,?6,?7,1,1)`).bind(sessionId,userId,planId,civilDate,status,startMs,endMs)]);
  return { userId, planId, sessionId };
}
function health(over: Partial<HealthKitActivityInput> = {}): HealthKitActivityInput {
  return { id: crypto.randomUUID(), date, start_date_local_ms: start, start_date_utc_ms: start,
    source_timezone: 'UTC', kind: 'strength', name: 'Watch strength', moving_time_sec: duration,
    elapsed_time_sec: duration, distance_m: null, average_watts: null, average_hr: null,
    max_hr: null, calories: null, elevation_gain_m: null, raw: null, ...over };
}

describe('native strength and HealthKit identity', () => {
  it('keeps the native workout once across state, calendar, recent activities and group projections', async () => {
    const { userId, sessionId } = await seed();
    const input = health();
    const row = await upsertHealthKitActivity(env.DB,userId,input);
    expect(row).toMatchObject({ canonical: 0, duplicate_of: `session:${sessionId}` });
    expect(row.deleted_at).not.toBeNull();
    const retry = await upsertHealthKitActivity(env.DB,userId,input);
    expect(retry.synced_at).toBe(row.synced_at);
    expect(await dedupeHealthKitAgainstIntervals(env.DB,userId)).toBe(0);
    expect(await getRecentActivities(env.DB,userId,{ to: date,range: 1 })).toEqual([]);
    const calendar = await getProjectedCalendar(env.DB,userId,date,date,date);
    expect(JSON.stringify(calendar)).not.toContain(row.id);
    expect(calendar).toEqual([{date,status:'completed',workout_id:null,real:true,items:[]}]);
    const jwt = await issueAppJwt(userId, 'test-secret');
    const response = await SELF.fetch('https://test/api/state', { headers: { Authorization: `Bearer ${jwt}` } });
    const state = await response.json<any>();
    expect(state.sessions.map((s: any) => s.id)).toContain(sessionId);
    expect(state.external_activities).toEqual([]);
    const group = await createGroup(env.DB,userId,'test');
    const feed = await getGroupFeed(env.DB,group.id,null,null,25,userId);
    expect(feed).toHaveLength(1);
    expect(JSON.stringify(feed)).toContain(sessionId);
    const series = await getGroupActivitySeries(env.DB,group.id,365,userId);
    expect(series[0]!.days.find(d => d.date === date)).toMatchObject({ sessions: 1,rides: 0 });
    expect((await getGroupStats(env.DB,group.id,365,userId))[0]!.workout_count).toBe(1);
  });

  it('retires an earlier HealthKit row in the completion transaction and sends its tombstone delta', async () => {
    const { userId, sessionId } = await seed('in_progress',start,null);
    // Completion uses now; this observed watch workout has the same span.
    const input = health({ elapsed_time_sec: Math.round((Date.now()-start)/1000) });
    const before = await upsertHealthKitActivity(env.DB,userId,input);
    expect(before.deleted_at).toBeNull();
    expect(await patchSession(env.DB,userId,sessionId,{ status:'completed' },0)).toMatchObject({ status:'completed' });
    const after = await env.DB.prepare('SELECT * FROM external_activities WHERE id=?1').bind(before.id).first<any>();
    expect(after.duplicate_of).toBe(`session:${sessionId}`);
    expect(after.synced_at).toBeGreaterThan(before.synced_at);
    const jwt = await issueAppJwt(userId,'test-secret');
    const delta = await SELF.fetch(`https://test/api/state?activities_since=${before.synced_at}`, { headers:{Authorization:`Bearer ${jwt}`} });
    expect((await delta.json<any>()).external_activities).toEqual([after]);
  });

  it('restores the observed workout after a native discard, without hiding or duplicating its source row', async () => {
    const { userId,sessionId } = await seed();
    const row = await upsertHealthKitActivity(env.DB,userId,health());
    await discardSession(env.DB,userId,sessionId,0);
    const restored = await env.DB.prepare('SELECT * FROM external_activities WHERE id=?1').bind(row.id).first<any>();
    expect(restored).toMatchObject({ deleted_at:null,canonical:1,duplicate_of:null });
    expect(restored.synced_at).toBeGreaterThan(row.synced_at);
  });

  it.each([
    ['missing absolute time', {start_date_utc_ms:null,source_timezone:null}],
    ['different kind', {kind:'run'}],
    ['unrelated end', {elapsed_time_sec:duration+600}],
    ['unrelated start', {start_date_utc_ms:start+600_000,start_date_local_ms:start+600_000}],
  ] as Array<[string,Partial<HealthKitActivityInput>]>)('does not suppress %s', async (_, over) => {
    const {userId}=await seed();
    expect((await upsertHealthKitActivity(env.DB,userId,health(over))).deleted_at).toBeNull();
  });

  it('does not match another member or a native workout without a recorded start', async () => {
    await seed();
    const {userId}=await seed('completed',null);
    expect((await upsertHealthKitActivity(env.DB,userId,health())).deleted_at).toBeNull();
  });

  it('leaves ambiguous native matches visible instead of picking an arbitrary workout', async () => {
    const {userId,planId}=await seed();
    const otherDate=new Date(start-86_400_000).toISOString().slice(0,10);
    await runWorkoutWriteBatch(env.DB,[env.DB.prepare(`INSERT INTO sessions
      (id,user_id,plan_id,date,status,started_at,completed_at,created_at,updated_at)
      VALUES (?1,?2,?3,?4,'completed',?5,?6,1,1)`)
      .bind(crypto.randomUUID(),userId,planId,otherDate,start,start+duration*1000)]);
    expect((await upsertHealthKitActivity(env.DB,userId,health())).deleted_at).toBeNull();
  });

  it('distinguishes the two identical wall clocks during the fall DST transition', async () => {
    const first=Date.parse('2026-11-01T08:30:00Z');
    const {userId,sessionId}=await seed('completed',first,first+duration*1000,'2026-11-01');
    const input=health({date:'2026-11-01',start_date_local_ms:Date.parse('2026-11-01T01:30:00Z'),
      source_timezone:'America/Los_Angeles',start_date_utc_ms:first});
    expect((await upsertHealthKitActivity(env.DB,userId,input)).duplicate_of).toBe(`session:${sessionId}`);
    expect((await upsertHealthKitActivity(env.DB,userId,{...input,id:crypto.randomUUID(),
      start_date_utc_ms:first+3_600_000})).deleted_at).toBeNull();
  });

  it('rolls back completion when reconciliation fails, retaining both acknowledged states', async () => {
    const {userId,sessionId}=await seed('in_progress',start,null);
    const row=await upsertHealthKitActivity(env.DB,userId,health({elapsed_time_sec:Math.round((Date.now()-start)/1000)}));
    await env.DB.prepare(`CREATE TRIGGER test_reconcile_abort BEFORE UPDATE ON external_activities
      WHEN NEW.duplicate_of LIKE 'session:%' BEGIN SELECT RAISE(ABORT,'test_reconcile_abort'); END`).run();
    try {
      await expect(patchSession(env.DB,userId,sessionId,{status:'completed'},0)).rejects.toThrow('test_reconcile_abort');
      expect(await env.DB.prepare('SELECT status FROM sessions WHERE id=?1').bind(sessionId).first('status')).toBe('in_progress');
      expect(await env.DB.prepare('SELECT deleted_at FROM external_activities WHERE id=?1').bind(row.id).first('deleted_at')).toBeNull();
    } finally { await env.DB.prepare('DROP TRIGGER test_reconcile_abort').run(); }
  });

  it.each([
    { label:'legacy local clock', localOffset:0, utcOffset:null, matches:true },
    { label:'same instant with different local clocks', localOffset:-14_400_000, utcOffset:0, matches:true },
    { label:'different instants with the same local clock', localOffset:0, utcOffset:3_600_000, matches:false },
  ])('reconciles Intervals after native discard using $label', async ({localOffset,utcOffset,matches}) => {
    const {userId,sessionId}=await seed();
    const ivId=`intervals:activity:${userId}:strength`;
    await env.DB.prepare(`INSERT INTO external_activities
      (id,user_id,source,external_id,date,kind,start_date_local_ms,start_date_utc_ms,synced_at)
      VALUES (?1,?2,'intervals','strength',?3,'strength',?4,?5,1)`)
      .bind(ivId,userId,date,start+localOffset,utcOffset===null?null:start+utcOffset).run();
    const row=await upsertHealthKitActivity(env.DB,userId,health());
    expect(row.duplicate_of).toBe(`session:${sessionId}`);
    await discardSession(env.DB,userId,sessionId,0);
    expect(await env.DB.prepare('SELECT duplicate_of FROM external_activities WHERE id=?1').bind(row.id).first('duplicate_of'))
      .toBe(matches ? ivId : null);
    expect(await dedupeHealthKitAgainstIntervals(env.DB,userId)).toBe(0);
  });

  it('rejects inconsistent source timing at the REST boundary before storing a row', async () => {
    const {userId}=await seed();
    const jwt=await issueAppJwt(userId,'test-secret');
    const input=health({source_timezone:'Asia/Tokyo'});
    const response=await SELF.fetch('https://test/api/activities/healthkit',{method:'POST',
      headers:{Authorization:`Bearer ${jwt}`,'content-type':'application/json'},body:JSON.stringify(input)});
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({error:'invalid_source_time'});
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM external_activities WHERE user_id=?1').bind(userId).first('n')).toBe(0);
  });

  it('retains an explicit Intervals instant independently of the civil date and raw payload', async () => {
    const {userId}=await seed();
    await env.DB.prepare("UPDATE users SET intervals_api_key='synthetic-key',intervals_athlete_id='synthetic-athlete' WHERE id=?1").bind(userId).run();
    const payload=[{id:'ride',type:'Ride',start_date_local:'2026-06-18T23:30:00',start_date:'2026-06-19T06:30:00Z',moving_time:1200}];
    const result=await syncExternalActivities(env.DB,env,{userId,today:'2026-06-19',pastDays:3,
      fetcher:async()=>({ok:true,status:200,json:async()=>payload})});
    expect(result.status).toBe('ok');
    const row=await env.DB.prepare("SELECT * FROM external_activities WHERE user_id=?1 AND source='intervals'").bind(userId).first<any>();
    expect(row).toMatchObject({date:'2026-06-18',start_date_utc_ms:Date.parse('2026-06-19T06:30:00Z')});
    await env.DB.prepare('UPDATE external_activities SET raw=NULL WHERE id=?1').bind(row.id).run();
    expect(await env.DB.prepare('SELECT start_date_utc_ms FROM external_activities WHERE id=?1').bind(row.id).first('start_date_utc_ms')).toBe(row.start_date_utc_ms);
  });

  it('retains the first civil date and instant when a same-UUID retry arrives after travel', async () => {
    const {userId}=await seed('planned');
    const input=health({ kind:'run',date:'2026-06-18',start_date_utc_ms:Date.parse('2026-06-19T06:30:00Z'),
      start_date_local_ms:Date.parse('2026-06-18T23:30:00Z'),source_timezone:'America/Los_Angeles' });
    const first=await upsertHealthKitActivity(env.DB,userId,input);
    const after=await upsertHealthKitActivity(env.DB,userId,{...input,date:'2026-06-19',
      start_date_local_ms:Date.parse('2026-06-19T15:30:00Z'),source_timezone:'Asia/Tokyo',average_hr:142});
    expect(after).toMatchObject({date:'2026-06-18',source_timezone:'America/Los_Angeles',average_hr:142});
    expect(after.start_date_utc_ms).toBe(input.start_date_utc_ms);
    expect(after.start_date_local_ms).toBe(first.start_date_local_ms);
  });

  it('clears an old Intervals instant when a corrected local start has no absolute timestamp', async () => {
    const { userId } = await seed();
    await env.DB.prepare("UPDATE users SET intervals_api_key='synthetic-key',intervals_athlete_id='synthetic-athlete' WHERE id=?1")
      .bind(userId).run();
    const activity = { id: 'ride', type: 'Ride', start_date_local: '2026-06-18T23:30:00',
      start_date: '2026-06-19T06:30:00Z', moving_time: 1200 };
    const sync = (payload: unknown) => syncExternalActivities(env.DB, env, {
      userId, today: '2026-06-19', pastDays: 3,
      fetcher: async () => ({ ok: true, status: 200, json: async () => [payload] }),
    });
    expect((await sync(activity)).status).toBe('ok');
    // An omitted absolute timestamp does not erase evidence for an unchanged start.
    expect((await sync({ ...activity, start_date: undefined, moving_time: 1500 })).status).toBe('ok');
    const read = () => env.DB.prepare("SELECT * FROM external_activities WHERE user_id=?1 AND source='intervals'")
      .bind(userId).first<any>();
    expect((await read()).start_date_utc_ms).toBe(Date.parse(activity.start_date));
    expect((await sync({ ...activity, start_date: undefined, start_date_local: '2026-06-19T01:00:00' })).status).toBe('ok');
    expect(await read()).toMatchObject({ date: '2026-06-19', start_date_utc_ms: null });
  });
});
