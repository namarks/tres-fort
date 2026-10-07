import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, expect, it } from 'vitest';
import { createPartnerWorkout, startPartnerSession, leavePartnerSession, cancelPartnerStart, getPlanTree, getOwnedSessionByDate,
  logSet, updateExercise, addTemplateExercise, deleteTemplateExercise, swapExercise, updatePlanTree,
  patchWorkoutAtVersion, setGroup, clearGroup, adjustToday } from '../src/db';
import { issueAppJwt } from '../src/auth';
import type { PartnerWorkoutInput, PartnerStartInput } from '../src/partnerTraining';

beforeAll(async () => {
  await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);
  await env.DB.prepare('UPDATE workout_write_fence SET enabled=1,activated_at=1 WHERE id=1').run();
});
async function member() {
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?,?,1)').bind(id,id).run();
  return id;
}
function copy(): PartnerWorkoutInput {
  const group = crypto.randomUUID();
  return {workout_id:crypto.randomUUID(),name:'Together',expected_plan_id:null,expected_version:0,
    slots:['ex_back_squat','ex_bench'].map((exercise_id,order_index)=>({id:crypto.randomUUID(),exercise_id,order_index,
      target_sets:3,target_reps:8,target_reps_max:12,target_rpe:8,rest_seconds:90,target_weight:40,
      target_weight_unit:'kg',target_duration_s:null,progression:'{"type":"double","increment":2}',
      cues:'Slow descent',is_warmup:order_index,group_id:group,group_rest_seconds:120,group_transition_seconds:10}))};
}
async function fixture() {
  const userId = await member(), input = copy();
  const created = await createPartnerWorkout(env.DB,userId,input);
  if (!('workout_id' in created) || !created.workout_id || !created.plan_id || created.version == null) throw Error(JSON.stringify(created));
  const start: PartnerStartInput = {id:crypto.randomUUID(),session_id:crypto.randomUUID(),partner_workout_id:crypto.randomUUID(),
    date:'2026-10-07',workout_id:created.workout_id,expected_plan_id:created.plan_id,expected_version:created.version,expected_attempt:0};
  return {userId,input,created,start};
}
async function started() {
  const f = await fixture();
  const result = await startPartnerSession(env.DB,f.userId,f.start);
  if (!('session' in result) || !result.session) throw Error(JSON.stringify(result));
  return {...f,session:result.session};
}
it('atomically creates a plan and full workout, keeping warmups, groups, units and all targets',async()=>{
  const f = await fixture(), tree = (await getPlanTree(env.DB,f.userId))!;
  expect(tree.version).toBe(1);
  expect(tree.workouts[0]!.exercises).toMatchObject(f.input.slots);
  expect((await env.DB.prepare('SELECT version FROM plan_snapshots WHERE plan_id=?').bind(tree.id).all()).results).toEqual([{version:1}]);
  expect(await createPartnerWorkout(env.DB,f.userId,JSON.parse(JSON.stringify(f.input)))).toEqual(f.created);
  expect((await getPlanTree(env.DB,f.userId))!.workouts).toHaveLength(1);
  expect(await createPartnerWorkout(env.DB,f.userId,{...f.input,name:'Different'})).toEqual({error:'idempotency_conflict'});
  expect(await createPartnerWorkout(env.DB,await member(),f.input)).toEqual({error:'idempotency_conflict'});
});
it('concurrent copy retries share one acknowledgement and invalid copies leave no plan',async()=>{
  const user = await member(), input = copy();
  const results = await Promise.all([createPartnerWorkout(env.DB,user,input),createPartnerWorkout(env.DB,user,input)]);
  expect(results[0]).toEqual(results[1]);
  expect((await getPlanTree(env.DB,user))!.workouts).toHaveLength(1);
  const empty = await member();
  expect(await createPartnerWorkout(env.DB,empty,{...copy(),slots:[{...copy().slots[0],target_reps:0}]})).toMatchObject({error:'invalid_fields'});
  expect(await getPlanTree(env.DB,empty)).toBeNull();
});
it('accepts the iPhone wire shape with omitted nullable slot fields and retries as the same copy',async()=>{
  const userId = await member(), jwt = await issueAppJwt(userId,env.APP_JWT_SECRET);
  // Swift's synthesized encoder omits nil slot fields. partnerPost explicitly
  // restores expected_plan_id and progression, which the wire validator requires.
  const input = {workout_id:crypto.randomUUID(),name:'Together',expected_plan_id:null,expected_version:0,
    slots:[{id:crypto.randomUUID(),exercise_id:'ex_back_squat',order_index:0,target_sets:3,
      target_reps:8,rest_seconds:90,target_weight_unit:'lb',is_warmup:0,progression:null}]};
  const post = (body: unknown) => SELF.fetch('https://test/api/partner/workouts',{
    method:'POST',headers:{Authorization:`Bearer ${jwt}`,'Content-Type':'application/json'},body:JSON.stringify(body)});
  const response = await post(input);
  expect(response.status).toBe(201);
  const receipt = await response.json();
  expect(receipt).toMatchObject({workout_id:input.workout_id,version:1});
  const nulls = {target_reps_max:null,target_rpe:null,target_weight:null,target_duration_s:null,cues:null,
    group_id:null,group_rest_seconds:null,group_transition_seconds:null};
  expect((await getPlanTree(env.DB,userId))!.workouts[0]!.exercises[0]).toMatchObject({...input.slots[0],...nulls});
  const retry = await post({...input,slots:[{...input.slots[0],...nulls}]});
  expect(retry.status).toBe(201);
  expect(await retry.json()).toEqual(receipt);
  expect((await getPlanTree(env.DB,userId))!.workouts).toHaveLength(1);
});
it('rolls back copy, plan, audit and snapshots together',async()=>{
  const user = await member(), input = copy();
  await env.DB.exec("CREATE TRIGGER fail_partner_audit BEFORE INSERT ON audit_log WHEN NEW.tool='create_partner_workout' BEGIN SELECT RAISE(ABORT,'partner test failure'); END");
  try {await expect(createPartnerWorkout(env.DB,user,input)).rejects.toThrow('partner test failure');}
  finally {await env.DB.exec('DROP TRIGGER fail_partner_audit');}
  expect(await getPlanTree(env.DB,user)).toBeNull();
  expect(await env.DB.prepare('SELECT id FROM audit_log WHERE user_id=?').bind(user).first()).toBeNull();
});
it('starts once with reviewed targets and rejects stale plans and another account',async()=>{
  const f = await started();
  expect(f.session).toMatchObject({status:'in_progress',attempt:1,partner_workout_id:f.start.partner_workout_id});
  expect(JSON.parse(f.session.runner_targets!)).toMatchObject({plan_version:1,slots:[{weight_unit:'kg',sets:3},{is_warmup:1}]});
  expect(await startPartnerSession(env.DB,f.userId,f.start)).toMatchObject({session:{id:f.session.id,attempt:1}});
  expect(await startPartnerSession(env.DB,await member(),f.start)).toEqual({error:'idempotency_conflict'});
  const stale = await fixture();
  expect(await startPartnerSession(env.DB,stale.userId,{...stale.start,expected_version:2})).toMatchObject({conflict:true});
  expect(await getOwnedSessionByDate(env.DB,stale.userId,stale.start.date)).toBeNull();
});
it('never replaces logged work or cancels it after a delayed setup response',async()=>{
  const f = await started();
  await logSet(env.DB,f.userId,{id:crypto.randomUUID(),session_id:f.session.id,
    exercise_id:'ex_back_squat',template_exercise_id:f.input.slots[0]!.id,set_index:1,weight:40,weight_unit:'kg',
    reps:8,source:'ios',expected_attempt:1});
  expect(await leavePartnerSession(env.DB,f.userId,f.session.id,f.start.partner_workout_id,1,true)).toEqual({error:'session_state_conflict'});
  expect(await leavePartnerSession(env.DB,f.userId,f.session.id,f.start.partner_workout_id,1,false)).toMatchObject({session:{status:'in_progress',partner_workout_id:null}});
  expect(await startPartnerSession(env.DB,f.userId,f.start)).toEqual({error:'session_state_conflict'});
  expect(await leavePartnerSession(env.DB,f.userId,f.session.id,f.start.partner_workout_id,1,true)).toEqual({error:'session_state_conflict'});
  expect(await startPartnerSession(env.DB,f.userId,{...f.start,id:crypto.randomUUID(),expected_attempt:1})).toEqual({error:'session_state_conflict'});
});
it('cancels only the named empty attempt, and a delayed start cannot revive it',async()=>{
  const f = await started();
  expect(await leavePartnerSession(env.DB,f.userId,f.session.id,f.start.partner_workout_id,0,true)).toEqual({error:'session_state_conflict'});
  expect(await leavePartnerSession(env.DB,f.userId,f.session.id,f.start.partner_workout_id,1,true)).toMatchObject({session:{status:'discarded',partner_workout_id:null}});
  expect(await startPartnerSession(env.DB,f.userId,f.start)).toEqual({error:'session_state_conflict'});
});
it('locks prescriptions at the SQL boundary and restores ordinary editing after leaving',async()=>{
  const f=await started(), before=(await getPlanTree(env.DB,f.userId))!;
  await expect(updateExercise(env.DB,f.userId,{template_exercise_id:f.input.slots[0]!.id},{target_reps:9})).rejects.toThrow('active_partner_workout');
  expect((await getPlanTree(env.DB,f.userId))!.version).toBe(before.version);
  const jwt=await issueAppJwt(f.userId,env.APP_JWT_SECRET);
  const response=await SELF.fetch(`https://test/api/workouts/${f.input.workout_id}/exercises/${f.input.slots[0]!.id}`,{
    method:'PATCH',headers:{'Content-Type':'application/json',Authorization:`Bearer ${jwt}`},body:JSON.stringify({target_reps:9,expected_version:1})});
  expect(response.status).toBe(409);expect(await response.json()).toMatchObject({error:'active_workout'});
  await leavePartnerSession(env.DB,f.userId,f.session.id,f.start.partner_workout_id,1,false);
  await updateExercise(env.DB,f.userId,{template_exercise_id:f.input.slots[0]!.id},{target_reps:9});
  expect((await getPlanTree(env.DB,f.userId))!.version).toBe(2);
});
it('rejects malformed dates and retired or foreign request fields before mutation',async()=>{
  const f=await fixture(), jwt=await issueAppJwt(f.userId,env.APP_JWT_SECRET);
  for(const body of [{...f.start,date:'2026-99-99'},{...f.start,date:'2026-02-31'},{...f.start,user_id:await member()}]) {
    const res=await SELF.fetch('https://test/api/partner/start',{method:'POST',headers:{Authorization:`Bearer ${jwt}`,'Content-Type':'application/json'},body:JSON.stringify(body)});
    expect(res.status).toBe(400);
  }
  expect(await getOwnedSessionByDate(env.DB,f.userId,f.start.date)).toBeNull();
});

it('cancellation fences an uncommitted Start and remains idempotent',async()=>{
  const f=await fixture();
  expect(await cancelPartnerStart(env.DB,f.userId,f.start)).toEqual({cancelled:true,session:null});
  expect(await startPartnerSession(env.DB,f.userId,f.start)).toEqual({error:'session_state_conflict'});
  expect(await cancelPartnerStart(env.DB,f.userId,f.start)).toEqual({cancelled:true,session:null});
  expect(await getOwnedSessionByDate(env.DB,f.userId,f.start.date)).toBeNull();
});
it('cancellation settles a committed empty Start but preserves a closed or logged lane',async()=>{
  const empty=await started();
  expect(await cancelPartnerStart(env.DB,empty.userId,empty.start)).toMatchObject({cancelled:true,session:{status:'discarded'}});
  expect(await cancelPartnerStart(env.DB,empty.userId,empty.start)).toMatchObject({cancelled:true,session:{status:'discarded'}});
  const closed=await started();
  await leavePartnerSession(env.DB,closed.userId,closed.session.id,closed.start.partner_workout_id,1,false);
  expect(await cancelPartnerStart(env.DB,closed.userId,closed.start)).toEqual({error:'session_state_conflict'});
  const logged=await started();
  await logSet(env.DB,logged.userId,{id:crypto.randomUUID(),session_id:logged.session.id,
    exercise_id:'ex_back_squat',template_exercise_id:logged.input.slots[0]!.id,set_index:1,weight:40,reps:8,source:'ios',expected_attempt:1});
  expect(await cancelPartnerStart(env.DB,logged.userId,logged.start)).toEqual({error:'session_state_conflict'});
  expect(await startPartnerSession(env.DB,logged.userId,logged.start)).toMatchObject({session:{status:'in_progress'}});
});
it('every structural writer is fenced without leaving partial versions or receipts',async()=>{
  const f=await started(), plan=(await getPlanTree(env.DB,f.userId))!, slot=f.input.slots[0]!;
  const mutations:[string,()=>Promise<unknown>][]=[
    ['delete',()=>deleteTemplateExercise(env.DB,f.userId,{template_exercise_id:slot.id})],
    ['swap',()=>swapExercise(env.DB,f.userId,{template_exercise_id:slot.id,to_exercise:'Bench Press',expected_version:1})],
    ['adjust',()=>adjustToday(env.DB,f.userId,'reduce_intensity')],
    ['ungroup',()=>clearGroup(env.DB,f.userId,slot.group_id!,1)],
    ['regroup',()=>setGroup(env.DB,f.userId,f.input.workout_id,slot.group_id!,f.input.slots.map(s=>s.id),{expected_version:1,round_rest:99})],
    ['rebuild',()=>updatePlanTree(env.DB,f.userId,{expected_version:1,workouts:[{name:'Replacement',exercises:[{exercise:'Back Squat',target_sets:2,target_reps:5}]}]})],
    ['rename',()=>patchWorkoutAtVersion(env.DB,f.userId,plan,f.input.workout_id,{name:'Different'})],
    ['add',()=>addTemplateExercise(env.DB,plan.id,{...slot,group_id:null,group_rest_seconds:null,group_transition_seconds:null,
      workout_id:f.input.workout_id,order_index:2})],
  ];
  for(const [name,mutate] of mutations) {
    try { expect(await mutate(),name).toMatchObject({error:'active_workout'}); }
    catch(error) { expect(String(error),name).toContain('active_partner_workout'); }
    expect((await getPlanTree(env.DB,f.userId))!.version,name).toBe(1);
  }
  expect((await getPlanTree(env.DB,f.userId))!.workouts[0]!.exercises).toMatchObject(f.input.slots);
});
it('concurrent cancel and start leave no active partner attempt',async()=>{
  for(let index=0;index<3;index++) {
    const f=await fixture();
    await Promise.all([startPartnerSession(env.DB,f.userId,f.start),cancelPartnerStart(env.DB,f.userId,f.start)]);
    const row=await getOwnedSessionByDate(env.DB,f.userId,f.start.date);
    expect(row?.status ?? 'absent').toMatch(/^(discarded|absent)$/);
    expect(await startPartnerSession(env.DB,f.userId,f.start)).toEqual({error:'session_state_conflict'});
  }
});
