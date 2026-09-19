import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, expect, it } from 'vitest';
import { createPlan, getPlanTree, getPlanSnapshot, patchWorkoutAtVersion, updatePlanTree,
  setPlanSchedule, setPlannedSession, getWorkoutInPlan, findWorkoutByRef,
  getProjectedCalendar, getOrCreateSession, patchSession, restorePlanSnapshot } from '../src/db';
import { serializePlanSnapshot } from '../src/planSnapshots';
import { parsePlanMeta } from '../src/types';

beforeAll(async () => applyD1Migrations(env.DB, env.TEST_MIGRATIONS));
async function fixture() {
  const userId = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?,?,1)').bind(userId,userId).run();
  await createPlan(env.DB,userId,'Library');
  const result = await updatePlanTree(env.DB,userId,{workouts:[
    {name:'Gym',day_label:'A',exercises:[{exercise:'bench',target_sets:3,target_reps:5}]},
    {name:'Hotel',day_label:'B',tags:[' Travel ', 'quick','travel'],exercises:[]},
  ]});
  if (!('plan' in result)) throw Error('fixture');
  const plan = result.plan;
  return {userId,plan,gym:plan.workouts[0]!,hotel:plan.workouts[1]!};
}
async function session(userId:string,planId:string,workoutId:string|null,date:string,status:string) {
  const id=crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO sessions (id,user_id,plan_id,workout_id,date,status,created_at,updated_at,attempt)
    VALUES (?,?,?,?,?,?,1,1,2)`).bind(id,userId,planId,workoutId,date,status).run();
  return id;
}
const attribution = {actor:'mcp' as const,operation:'update_workout',note:'Archived workout.'};

it('normalizes tags and snapshots every metadata field in the same atomic write', async () => {
  const {userId,plan,gym,hotel}=await fixture();
  expect(hotel.tags).toBe('["travel","quick"]');
  const result=await patchWorkoutAtVersion(env.DB,userId,plan,gym.id,{tags:[' QUICK ','hotel','quick']},attribution);
  expect(result).toMatchObject({tags:'["quick","hotel"]',archived_at:null});
  const tree=(await getPlanTree(env.DB,userId))!;
  expect(tree.version).toBe(plan.version+1);
  expect((await getPlanSnapshot(env.DB,userId,plan.id,tree.version))?.parsed).toEqual(serializePlanSnapshot(tree));
  expect((await env.DB.prepare('SELECT id FROM audit_log WHERE user_id=? AND tool=?').bind(userId,'update_workout').all()).results).toHaveLength(1);
  expect((await env.DB.prepare("SELECT body FROM notes WHERE user_id=? AND author='coach'").bind(userId).all()).results).toContainEqual({body:'Archived workout.'});
});

it.each([{tags:['']},{tags:['a'.repeat(33)]},{tags:['İ'.repeat(17)]},{tags:Array(13).fill('x')},{tags:'travel'},{archived_at:-1},{archived_at:1.5}])('rejects invalid metadata before writing: %j', async patch => {
  const {userId,plan,gym}=await fixture();
  expect(await patchWorkoutAtVersion(env.DB,userId,plan,gym.id,patch as never)).toHaveProperty('error','invalid_fields');
  expect((await getPlanTree(env.DB,userId))?.version).toBe(plan.version);
});

it('archives atomically, clears explicit and legacy planned dates, and retains completed history identities', async () => {
  const {userId,plan,gym,hotel}=await fixture();
  await setPlanSchedule(env.DB,userId,{mon:gym.id,tue:hotel.id});
  const current=(await getPlanTree(env.DB,userId))!;
  const done=await session(userId,plan.id,gym.id,'2026-09-07','completed');
  const future=await session(userId,plan.id,gym.id,'2026-09-21','planned');
  const legacy=await session(userId,plan.id,null,'2026-09-28','planned');
  const other=await session(userId,plan.id,hotel.id,'2026-09-22','planned');
  const slot=gym.exercises[0]!;
  const set=crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,logged_at,source)
    VALUES (?,?,'ex_bench',?,1,100,5,1,'ios')`).bind(set,done,slot.id).run();
  expect(await patchWorkoutAtVersion(env.DB,userId,current,gym.id,{archived_at:123},attribution)).toMatchObject({archived_at:123});
  const tree=(await getPlanTree(env.DB,userId))!;
  expect(tree.workouts).toHaveLength(2);
  expect(parsePlanMeta(tree.meta).schedule.week).toMatchObject({mon:null,tue:hotel.id});
  expect(await env.DB.prepare('SELECT workout_id,status,attempt FROM sessions WHERE id=?').bind(done).first()).toEqual({workout_id:gym.id,status:'completed',attempt:2});
  for (const id of [future,legacy]) expect(await env.DB.prepare('SELECT workout_id,status,attempt FROM sessions WHERE id=?').bind(id).first()).toEqual({workout_id:null,status:'skipped',attempt:3});
  expect(await env.DB.prepare('SELECT workout_id,attempt FROM sessions WHERE id=?').bind(other).first()).toEqual({workout_id:hotel.id,attempt:2});
  expect(await env.DB.prepare('SELECT template_exercise_id FROM set_logs WHERE id=?').bind(set).first('template_exercise_id')).toBe(slot.id);
  expect((await env.DB.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
});

it.each(['explicit','schedule','logged-slot'])('rejects an active %s reference without any write',async kind => {
  const {userId,plan,gym,hotel}=await fixture();
  if(kind==='schedule') await setPlanSchedule(env.DB,userId,{mon:gym.id});
  const current=(await getPlanTree(env.DB,userId))!;
  const id=await session(userId,plan.id,kind==='explicit'?gym.id:null,'2026-09-21','in_progress');
  if(kind==='logged-slot') await env.DB.prepare(`INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,logged_at,source)
    VALUES (?,?,'ex_bench',?,1,100,5,1,'ios')`).bind(crypto.randomUUID(),id,gym.exercises[0]!.id).run();
  expect(await patchWorkoutAtVersion(env.DB,userId,current,gym.id,{archived_at:123},attribution)).toEqual({error:'active_workout'});
  expect((await getPlanTree(env.DB,userId))?.version).toBe(current.version);
  // An unrelated active workout is not a reason to block this archive.
  expect(await patchWorkoutAtVersion(env.DB,userId,current,hotel.id,{archived_at:123})).toMatchObject({archived_at:123});
});

it('fences every resolver and the write-time session race, while restore does not reintroduce scheduling',async()=>{
  const {userId,plan,gym}=await fixture();
  await patchWorkoutAtVersion(env.DB,userId,plan,gym.id,{archived_at:123});
  expect(await getWorkoutInPlan(env.DB,plan.id,gym.id)).toBeNull();
  expect(await findWorkoutByRef(env.DB,plan.id,'Gym')).toBeNull();
  expect(await setPlanSchedule(env.DB,userId,{mon:gym.id})).toEqual({error:'unknown_day_ref',ref:gym.id});
  expect(await setPlannedSession(env.DB,userId,'2026-09-21',gym.id,0)).toEqual({error:'unknown_day_ref',ref:gym.id});
  await expect(getOrCreateSession(env.DB,userId,plan.id,'2026-09-21',gym.id)).rejects.toThrow('workout_archived_assignment');
  expect((await env.DB.prepare('SELECT id FROM sessions WHERE user_id=?').bind(userId).all()).results).toEqual([]);
  const current=(await getPlanTree(env.DB,userId))!;
  expect(await patchWorkoutAtVersion(env.DB,userId,current,gym.id,{archived_at:null})).toMatchObject({archived_at:null});
  expect(await getWorkoutInPlan(env.DB,plan.id,gym.id)).not.toBeNull();
  expect(parsePlanMeta((await getPlanTree(env.DB,userId))!.meta).schedule.week.mon).toBeNull();
});

it.each(['planned', 'in_progress'])('follows explicit workout references when a %s session retains its older plan id', async status => {
  const {userId,plan:oldPlan}=await fixture();
  const original=await getOrCreateSession(env.DB,userId,oldPlan.id,'2026-09-21',null);
  await createPlan(env.DB,userId,'Replacement');
  const result=await updatePlanTree(env.DB,userId,{workouts:[{name:'New Gym',exercises:[]}]});
  if(!('plan' in result)) throw Error('replacement');
  const plan=result.plan, workout=plan.workouts[0]!;
  const pinned=await getOrCreateSession(env.DB,userId,plan.id,'2026-09-21',workout.id);
  expect(pinned).toMatchObject({id:original.id,plan_id:oldPlan.id,workout_id:workout.id});
  if(status==='in_progress') await patchSession(env.DB,userId,pinned.id,{status});
  const archived=await patchWorkoutAtVersion(env.DB,userId,plan,workout.id,{archived_at:123});
  if(status==='in_progress') {
    expect(archived).toEqual({error:'active_workout'});
    expect((await getPlanTree(env.DB,userId))?.version).toBe(plan.version);
  } else {
    expect(archived).toMatchObject({archived_at:123});
    expect(await env.DB.prepare('SELECT status,workout_id,attempt FROM sessions WHERE id=?').bind(pinned.id).first())
      .toEqual({status:'skipped',workout_id:null,attempt:pinned.attempt+1});
  }
});

it('preserves omitted metadata across an older coach rebuild and allows reviewed restore',async()=>{
  const {userId,plan,gym}=await fixture();
  await patchWorkoutAtVersion(env.DB,userId,plan,gym.id,{tags:['quick'],archived_at:123});
  const archived=(await getPlanTree(env.DB,userId))!;
  const rebuilt=await updatePlanTree(env.DB,userId,{expected_version:archived.version,workouts:[{name:'Gym',day_label:'A',exercises:[]}]});
  expect(rebuilt).toHaveProperty('plan');
  if(!('plan' in rebuilt)) throw Error('rebuild');
  expect(rebuilt.plan.workouts[0]).toMatchObject({tags:'["quick"]',archived_at:123});
  const restored=await restorePlanSnapshot(env.DB,userId,{plan_id:plan.id,snapshot_version:archived.version,expected_version:rebuilt.plan.version,actor:'ios'});
  expect(restored).toHaveProperty('ok',true);
  expect((await getPlanTree(env.DB,userId))?.workouts[0]).toMatchObject({id:gym.id,tags:'["quick"]',archived_at:123});
});

it('rejects a stale archive and retains the newer tags',async()=>{
  const {userId,plan,gym}=await fixture();
  await patchWorkoutAtVersion(env.DB,userId,plan,gym.id,{tags:['quick']});
  expect(await patchWorkoutAtVersion(env.DB,userId,plan,gym.id,{archived_at:123})).toEqual({conflict:true,current_version:plan.version+1});
  expect((await getPlanTree(env.DB,userId))?.workouts[0]).toMatchObject({tags:'["quick"]',archived_at:null});
});

it('treats an archived schedule id as rest while keeping completed calendar history',async()=>{
  const {userId,plan,gym}=await fixture();
  await patchWorkoutAtVersion(env.DB,userId,plan,gym.id,{archived_at:123});
  // Simulate stale persisted schedule data independently of the archive scrub.
  await env.DB.prepare('UPDATE plans SET meta=? WHERE id=?').bind(JSON.stringify({schedule:{version:1,week:{mon:gym.id}}}),plan.id).run();
  const cells=await getProjectedCalendar(env.DB,userId,'2026-09-21','2026-09-21','2026-09-21');
  expect(cells).toMatchObject([{status:'rest',workout_id:null}]);
});

it('rejects a runner that starts between archive validation and its atomic claim',async()=>{
  const {userId,plan,gym}=await fixture();
  let injected=false;
  const racing = new Proxy(env.DB,{get(target,key){
    if(key==='batch') return async (statements:D1PreparedStatement[])=>{
      if(!injected){injected=true;await session(userId,plan.id,gym.id,'2026-09-21','in_progress');}
      return target.batch(statements);
    };
    const value=Reflect.get(target,key,target);
    return typeof value==='function'?value.bind(target):value;
  }});
  expect(await patchWorkoutAtVersion(racing,userId,plan,gym.id,{archived_at:123},attribution)).toEqual({error:'active_workout'});
  expect(injected).toBe(true);
  expect((await getPlanTree(env.DB,userId))?.version).toBe(plan.version);
  expect((await env.DB.prepare("SELECT id FROM audit_log WHERE user_id=? AND tool='update_workout'").bind(userId).all()).results).toEqual([]);
});

it('rolls archive and schedule cleanup back if its audit cannot commit',async()=>{
  const {userId,plan,gym}=await fixture();
  await setPlanSchedule(env.DB,userId,{mon:gym.id});
  const current=(await getPlanTree(env.DB,userId))!;
  const future=await session(userId,plan.id,gym.id,'2026-09-21','planned');
  await env.DB.prepare(`CREATE TRIGGER synthetic_archive_audit_failure BEFORE INSERT ON audit_log
    WHEN NEW.tool='update_workout' BEGIN SELECT RAISE(ABORT,'synthetic_audit_failure'); END`).run();
  await expect(patchWorkoutAtVersion(env.DB,userId,current,gym.id,{archived_at:123},attribution)).rejects.toThrow('synthetic_audit_failure');
  expect((await getPlanTree(env.DB,userId))).toEqual(current);
  expect(await env.DB.prepare('SELECT workout_id,status,attempt FROM sessions WHERE id=?').bind(future).first()).toEqual({workout_id:gym.id,status:'planned',attempt:2});
});

async function transportFixture() {
  const signIn=await SELF.fetch('https://tres-fort.test/auth/dev',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({secret:'test-dev'})});
  const {jwt}=await signIn.json<{jwt:string}>();
  const api=async(path:string,method='GET',body?:unknown)=>{
    const response=await SELF.fetch(`https://tres-fort.test/api/${path}`,{method,headers:{'content-type':'application/json',Authorization:`Bearer ${jwt}`},...(body===undefined?{}:{body:JSON.stringify(body)})});
    return {status:response.status,body:await response.json<any>()};
  };
  const tool=async(name:string,args:unknown)=>{
    const response=await SELF.fetch('https://tres-fort.test/mcp',{method:'POST',headers:{'content-type':'application/json',Authorization:'Bearer test-mcp-token'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}})});
    const rpc=await response.json<any>(); return JSON.parse(rpc.result.content[0].text);
  };
  await api('plan/active','PUT',{name:'Library'});
  return {api,tool};
}

it.each(['workouts','days'])('keeps %s REST aliases, sync metadata and permanent archive rejection consistent',async path=>{
  const {api}=await transportFixture();
  const created=await api(path,'POST',{name:'Hotel',tags:['travel']});
  expect(created.status).toBe(201);
  const id=created.body.id;
  const tree=(await api('plan/active')).body;
  expect((await api(`${path}/${id}`,'PATCH',{archived_at:123})).status).toBe(400);
  expect((await api(`${path}/${id}`,'PATCH',{archived_at:123,expected_version:tree.version})).status).toBe(200);
  const synced=(await api('state')).body;
  expect(synced.plan.workouts[0]).toMatchObject({id,tags:'["travel"]',archived_at:123});
  expect(synced.plan.days).toEqual(synced.plan.workouts);
  expect(await api('sessions','POST',{date:'2026-09-21',day_template_id:id})).toMatchObject({status:422,body:{error:'unknown_day'}});
  expect(await api('calendar/2026-09-21','PUT',{day_template_id:id,expected_attempt:0})).toMatchObject({status:400,body:{error:'unknown_day_ref'}});
});

it.each(['day','workout'])('exposes tags and archive through add_%s and update_%s with atomic coach notes',async suffix=>{
  const {api,tool}=await transportFixture();
  const created=await tool(`add_${suffix}`,{name:'Hotel',tags:['travel']});
  expect(created).toMatchObject({tags:'["travel"]',archived_at:null});
  expect(await tool(`update_${suffix}`,{day:'Hotel',patch:{archived_at:123,tags:['quick']}})).toMatchObject({archived_at:123,tags:'["quick"]'});
  expect(await tool('set_planned_session',{date:'2026-09-21',day:'Hotel',expected_attempt:0})).toMatchObject({error:'unknown_day_ref'});
  expect(await tool(`update_${suffix}`,{day:'Hotel',patch:{archived_at:null}})).toMatchObject({archived_at:null});
  expect((await api('plan/active')).body.workouts[0]).toMatchObject({tags:'["quick"]',archived_at:null});
});

it('restoring an archived snapshot after a rebuild turns dated assignments into explicit rest', async()=>{
  const {userId,plan,gym}=await fixture();
  await patchWorkoutAtVersion(env.DB,userId,plan,gym.id,{archived_at:123});
  const archived=(await getPlanTree(env.DB,userId))!;
  await patchWorkoutAtVersion(env.DB,userId,archived,gym.id,{archived_at:null});
  const rebuilt=await updatePlanTree(env.DB,userId,{workouts:[{name:'Gym',day_label:'A',exercises:[]}]});
  if(!('plan' in rebuilt)) throw Error('rebuild');
  const freshGym=rebuilt.plan.workouts[0]!;
  const assignment=await setPlannedSession(env.DB,userId,'2026-09-21',freshGym.id,0);
  if(!('session' in assignment)) throw Error('assignment');
  expect(await restorePlanSnapshot(env.DB,userId,{plan_id:plan.id,snapshot_version:archived.version,expected_version:rebuilt.plan.version,actor:'ios'})).toHaveProperty('ok',true);
  expect(await env.DB.prepare('SELECT status,workout_id,attempt FROM sessions WHERE id=?').bind(assignment.session.id).first())
    .toEqual({status:'skipped',workout_id:null,attempt:assignment.session.attempt+1});
});

it.each(['before', 'during'])('fences a cross-plan runner starting %s snapshot restore', async timing => {
  const {userId,plan:oldPlan}=await fixture();
  const original=await getOrCreateSession(env.DB,userId,oldPlan.id,'2026-09-21',null);
  await createPlan(env.DB,userId,'Replacement');
  const result=await updatePlanTree(env.DB,userId,{workouts:[{name:'New Gym',exercises:[]}]});
  if(!('plan' in result)) throw Error('replacement');
  const workout=result.plan.workouts[0]!;
  await patchWorkoutAtVersion(env.DB,userId,result.plan,workout.id,{archived_at:123});
  const archived=(await getPlanTree(env.DB,userId))!;
  await patchWorkoutAtVersion(env.DB,userId,archived,workout.id,{archived_at:null});
  const plan=(await getPlanTree(env.DB,userId))!;
  const pinned=await getOrCreateSession(env.DB,userId,plan.id,'2026-09-21',workout.id);
  expect(pinned).toMatchObject({id:original.id,plan_id:oldPlan.id,workout_id:workout.id});
  if(timing==='before') await patchSession(env.DB,userId,pinned.id,{status:'in_progress'});
  let injected=false;
  const db=timing==='before' ? env.DB : new Proxy(env.DB,{get(target,key){
    if(key==='batch') return async (statements:D1PreparedStatement[])=>{
      if(!injected){injected=true;await patchSession(env.DB,userId,pinned.id,{status:'in_progress'});}
      return target.batch(statements);
    };
    const value=Reflect.get(target,key,target);
    return typeof value==='function'?value.bind(target):value;
  }});
  expect(await restorePlanSnapshot(db,userId,{plan_id:plan.id,snapshot_version:archived.version,expected_version:plan.version,actor:'ios'}))
    .toEqual({error:'active_workout'});
  if(timing==='during') expect(injected).toBe(true);
  expect(await getPlanTree(env.DB,userId)).toEqual(plan);
  expect(await env.DB.prepare('SELECT workout_id,status FROM sessions WHERE id=?').bind(pinned.id).first())
    .toEqual({workout_id:workout.id,status:'in_progress'});
});
