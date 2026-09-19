import { runWorkoutWriteStatement } from '../src/workout-write-fence';
import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, expect, it } from 'vitest';
import { createPlan, updatePlanTree, getPlanTree, startFreestyleSession, logSet, patchSession,
  getFreestyleWorkoutDraft, saveFreestyleWorkout, getState, getOrCreateSession,
  setPlanSchedule, deleteWorkout, getOwnedSessionByDate, discardSession } from '../src/db';
import { deriveFreestylePrescriptions } from '../src/freestyle';

beforeAll(async()=>{await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);await env.DB.prepare('UPDATE workout_write_fence SET enabled=1,activated_at=1 WHERE id=1').run();});
async function fixture(){
 const userId=crypto.randomUUID();
 await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?,?,1)').bind(userId,userId).run();
 await createPlan(env.DB,userId,'Workouts');
 const plan=(await getPlanTree(env.DB,userId))!;
 const result=await startFreestyleSession(env.DB,userId,'2026-09-21',0);
 if(!('session' in result))throw Error(JSON.stringify(result));
 return {userId,plan,session:result.session!};
}
async function log(f:Awaited<ReturnType<typeof fixture>>,weight=100,reps=5,extra={}){
 return logSet(env.DB,f.userId,{id:crypto.randomUUID(),session_id:f.session.id,exercise_id:'ex_bench',
  set_index:1,weight,reps,source:'ios',expected_attempt:f.session.attempt,...extra});
}
async function draft(f:Awaited<ReturnType<typeof fixture>>){
 await patchSession(env.DB,f.userId,f.session.id,{status:'completed'},f.session.attempt);
 const d=await getFreestyleWorkoutDraft(env.DB,f.userId,f.session.id);
 if('error' in d)throw Error(d.error);
 return {workout_id:crypto.randomUUID(),name:'Hotel',expected_plan_id:f.plan.id,expected_version:f.plan.version,
  expected_attempt:f.session.attempt,source_signature:d.source_signature,slots:d.slots.map(({is_timed,...s})=>s)};
}
it('starts an explicit, immediately durable freestyle session without a library write',async()=>{
 const f=await fixture();expect(f.session).toMatchObject({kind:'freestyle',workout_id:null,status:'in_progress',attempt:0});
 expect((await getPlanTree(env.DB,f.userId))?.version).toBe(f.plan.version);
 expect(await startFreestyleSession(env.DB,f.userId,f.session.date,0)).toEqual({session:f.session});
 expect(await getOrCreateSession(env.DB,f.userId,f.plan.id,f.session.date,null)).toEqual(f.session);
});
it('saves reviewed cohorts once, advances attempt, snapshots, and preserves logs',async()=>{
 const f=await fixture();await log(f,100,5);await log(f,100,8);await log(f,135,3);await log(f,45,12,{is_warmup:true});
 const input=await draft(f);expect(input.slots).toMatchObject([{target_sets:2,target_reps:7,target_weight:100},{target_sets:1,target_reps:3,target_weight:135}]);
 const result=await saveFreestyleWorkout(env.DB,f.userId,f.session.id,input);
 expect(result).toMatchObject({workout_id:input.workout_id,version:f.plan.version+1,session:{attempt:1,kind:'freestyle'}});
 expect(await saveFreestyleWorkout(env.DB,f.userId,f.session.id,input)).toEqual(result);
 const reordered = Object.fromEntries(Object.entries(input).reverse()) as typeof input;
 reordered.slots = input.slots.map(s => Object.fromEntries(Object.entries(s).reverse()) as typeof s);
 expect(await saveFreestyleWorkout(env.DB,f.userId,f.session.id,reordered)).toEqual(result);
 const plan=(await getPlanTree(env.DB,f.userId))!;expect(plan.workouts).toHaveLength(1);
 expect(plan.workouts[0]!.exercises.map(s=>[s.target_sets,s.target_weight])).toEqual([[2,100],[1,135]]);
 await expect(log(f)).rejects.toThrow('session_attempt_conflict');
 expect((await env.DB.prepare('SELECT id FROM set_logs WHERE session_id=? AND template_exercise_id IS NOT NULL').bind(f.session.id).all()).results).toEqual([]);
 expect((await env.DB.prepare("SELECT id FROM audit_log WHERE user_id=? AND tool='save_freestyle_workout'").bind(f.userId).all()).results).toHaveLength(1);
});
it('invalidates source review after a late set and commits nothing',async()=>{
 const f=await fixture();await log(f);const input=await draft(f);await log(f,125,4);
 expect(await saveFreestyleWorkout(env.DB,f.userId,f.session.id,input)).toEqual({error:'session_state_conflict'});
 expect((await getPlanTree(env.DB,f.userId))?.version).toBe(f.plan.version);
});
it('converts an explicit rest date only through a new generation',async()=>{
 const f=await fixture();await runWorkoutWriteStatement(env.DB,env.DB.prepare("UPDATE sessions SET status='discarded' WHERE id=?").bind(f.session.id));
 const restarted=await startFreestyleSession(env.DB,f.userId,f.session.date,0);
 expect(restarted).toMatchObject({session:{attempt:1,status:'in_progress'}});
 await expect(log(f)).rejects.toThrow('session_attempt_conflict');
});

it('keeps timed, rep, assistance, added-load, warmup and variation cohorts separate',()=>{
 const rows = [
  {id:'a',exercise_id:'pull',weight:-30,reps:4,is_timed:0},
  {id:'b',exercise_id:'pull',weight:-30,reps:7,is_timed:0},
  {id:'c',exercise_id:'pull',weight:0,reps:8,is_timed:0},
  {id:'d',exercise_id:'pull',weight:20,reps:3,is_timed:0},
  {id:'e',exercise_id:'pull',weight:20,reps:1,is_timed:1,duration_s:21},
  {id:'f',exercise_id:'pull',weight:20,reps:1,is_timed:1,duration_s:24},
  {id:'g',exercise_id:'variation',weight:20,reps:9,is_timed:0},
  {id:'h',exercise_id:'pull',weight:20,reps:99,is_timed:0,is_warmup:1},
  {id:'i',exercise_id:'pull',weight:20,reps:99,is_timed:0,deleted_at:1},
 ].map((s,i)=>({user_id:'u',session_id:'s',template_exercise_id:null,set_index:i,rpe:null,notes:null,
  is_warmup:0,logged_at:i,updated_at:i,deleted_at:null,duration_s:null,source:'ios' as const,...s}));
 expect(deriveFreestylePrescriptions(rows).map(s=>[s.exercise_id,s.target_weight,s.target_sets,s.target_reps,s.target_duration_s]))
  .toEqual([['pull',-30,2,6,null],['pull',0,1,8,null],['pull',20,1,3,null],['pull',20,2,1,23],['variation',20,1,9,null]]);
});

it('rejects invalid and foreign saves without a partial workout or version change',async()=>{
 const f=await fixture();await log(f);const input=await draft(f);
 const other=await fixture();
 expect(await saveFreestyleWorkout(env.DB,other.userId,f.session.id,input)).toEqual({error:'not_found'});
 const invalid=await saveFreestyleWorkout(env.DB,f.userId,f.session.id,{...input,slots:[{...input.slots[0]!,target_sets:0}]});
 expect(invalid).toMatchObject({error:'invalid_fields'});
 expect((await getPlanTree(env.DB,f.userId))?.version).toBe(f.plan.version);
 expect((await getPlanTree(env.DB,f.userId))?.workouts).toEqual([]);
});

it('concurrent same-request saves return one committed acknowledgement',async()=>{
 const f=await fixture();await log(f);const input=await draft(f);
 const results=await Promise.all([saveFreestyleWorkout(env.DB,f.userId,f.session.id,input),saveFreestyleWorkout(env.DB,f.userId,f.session.id,input)]);
 expect(results[0]).toEqual(results[1]);expect(results[0]).toMatchObject({version:f.plan.version+1});
 expect((await getPlanTree(env.DB,f.userId))?.workouts).toHaveLength(1);
 expect(await saveFreestyleWorkout(env.DB,f.userId,f.session.id,{...input,name:'Changed'})).toEqual({error:'idempotency_conflict'});
});

it('rolls back the complete save when a statement fails',async()=>{
 const f=await fixture();await log(f);const input=await draft(f);
 await env.DB.exec("CREATE TRIGGER reject_freestyle_receipt BEFORE INSERT ON freestyle_workout_receipts BEGIN SELECT RAISE(ABORT,'test rollback'); END");
 try { await expect(saveFreestyleWorkout(env.DB,f.userId,f.session.id,input)).rejects.toThrow('test rollback'); }
 finally { await env.DB.exec('DROP TRIGGER reject_freestyle_receipt'); }
 expect((await getPlanTree(env.DB,f.userId))?.version).toBe(f.plan.version);
 expect((await getPlanTree(env.DB,f.userId))?.workouts).toEqual([]);
 expect(await getOwnedSessionByDate(env.DB,f.userId,f.session.date)).toMatchObject({attempt:0,workout_id:null});
});

it('uses one REST contract for freestyle start, sync, completed correction and reviewed save',async()=>{
 const {issueAppJwt}=await import('../src/auth');
 const f=await fixture();const jwt=await issueAppJwt(f.userId,env.APP_JWT_SECRET);
 const headers={'Content-Type':'application/json',Authorization:`Bearer ${jwt}`};
 const request=(path:string,method:string,body?:unknown)=>SELF.fetch(`https://test/api/${path}`,{
  method,headers,...(body===undefined?{}:{body:JSON.stringify(body)}),
 });
 const started=await request('sessions','POST',{date:f.session.date,kind:'freestyle',expected_attempt:0});
 expect(started.status).toBe(201);
 expect(await started.json()).toMatchObject({id:f.session.id,kind:'freestyle',status:'in_progress'});
 const set=await log(f);
 const synced=await request('state','GET');
 expect(await synced.json()).toMatchObject({sessions:[{id:f.session.id,kind:'freestyle',status:'in_progress'}],sets:[{id:set.set.id}]});
 const complete=await request(`sessions/${f.session.id}?expected_attempt=0`,'PATCH',{status:'completed'});
 expect(complete.status).toBe(200);
 const correction=await request(`sets/${set.set.id}`,'PATCH',{reps:10});
 expect(correction.status).toBe(200);
 expect(await correction.json()).toMatchObject({id:set.set.id,reps:10});
 const input=await draft(f);
 expect(input.slots[0]?.target_reps).toBe(10);
 const saved=await request(`sessions/${f.session.id}/save-workout`,'POST',input);
 expect(saved.status).toBe(201);expect(await saved.json()).toMatchObject({workout_id:input.workout_id,session:{kind:'freestyle',attempt:1}});
 const retry=await request(`sessions/${f.session.id}/save-workout`,'POST',input);
 expect(retry.status).toBe(201);
});

it('explicitly restarts discarded freestyle as planned with a new attempt',async()=>{
 const {discardSession,reviveDiscardedSession}=await import('../src/db');
 const f=await fixture();await log(f);
 await discardSession(env.DB,f.userId,f.session.id,0);
 const restarted=await reviveDiscardedSession(env.DB,f.userId,f.session.id,0,null,true);
 expect(restarted).toMatchObject({kind:'planned',status:'planned',attempt:1});
 await expect(log(f)).rejects.toThrow('session_attempt_conflict');
});

it('freestyle wins over the schedule without blocking removal of that reusable workout',async()=>{
 const {addWorkoutAtVersion}=await import('../src/db');
 const {projectCalendar}=await import('../src/calendarProjection');
 const f=await fixture();
 const created=await addWorkoutAtVersion(env.DB,f.userId,f.plan,'Scheduled',null,0);
 if(!('id' in created))throw Error(JSON.stringify(created));
 const plan=(await getPlanTree(env.DB,f.userId))!;
 await setPlanSchedule(env.DB,f.userId,{mon:created.id},plan.version);
 const cells=projectCalendar(f.plan,{version:1,week:{mon:created.id,tue:null,wed:null,thu:null,fri:null,sat:null,sun:null}},[f.session],f.session.date,f.session.date,f.session.date,[created.id]);
 expect(cells[0]).toMatchObject({status:'in_progress',real:true,workout_id:null});
 expect(await deleteWorkout(env.DB,f.userId,created.id)).toBeTruthy();
 expect(await getOwnedSessionByDate(env.DB,f.userId,f.session.date)).toMatchObject({kind:'freestyle',status:'in_progress',workout_id:null});
});

it('settles an old planned set UUID after the date restarts as freestyle',async()=>{
 const {discardSession}=await import('../src/db');
 const f=await fixture();
 await discardSession(env.DB,f.userId,f.session.id,0);
 const {reviveDiscardedSession}=await import('../src/db');
 const planned=await reviveDiscardedSession(env.DB,f.userId,f.session.id,0,null,true);
 if(!planned || 'error' in planned)throw Error('restart');
 const input={id:crypto.randomUUID(),session_id:planned.id,exercise_id:'ex_bench',set_index:1,
  weight:100,reps:5,source:'ios' as const,expected_attempt:1,template_exercise_id:'former-slot'};
 await logSet(env.DB,f.userId,input);
 await discardSession(env.DB,f.userId,planned.id,1);
 await startFreestyleSession(env.DB,f.userId,planned.date,1);
 const retry=await logSet(env.DB,f.userId,{...input});
 expect(retry).toMatchObject({deduped:true,session:{kind:'freestyle',attempt:2}});
 expect(retry.set.deleted_at).not.toBeNull();
});

it('keeps an explicitly started freestyle active after deleting its final set',async()=>{
 const {patchSet}=await import('../src/db');
 const f=await fixture();const logged=await log(f);
 await patchSet(env.DB,f.userId,logged.set.id,{deleted:true});
 expect(await getOwnedSessionByDate(env.DB,f.userId,f.session.date))
  .toMatchObject({kind:'freestyle',status:'in_progress',started_at:f.session.started_at,attempt:0});
});

it('lets explicit legacy MCP logging restart its discarded freestyle generation',async()=>{
 const {discardSession}=await import('../src/db');
 const f=await fixture();const date='2026-09-22';
 const first=await startFreestyleSession(env.DB,f.userId,date,0,'mcp');
 if(!first.session)throw Error('start');
 await discardSession(env.DB,f.userId,first.session.id,0);
 const restarted=await getOrCreateSession(env.DB,f.userId,f.plan.id,date,null);
 expect(restarted).toMatchObject({kind:'freestyle',status:'in_progress',attempt:1,write_protocol:'legacy'});
});

it('exports and deletes the account after saving a freestyle workout',async()=>{
 const {deleteUserAccount,exportUserData}=await import('../src/db');
 const f=await fixture();await log(f);const input=await draft(f);
 await saveFreestyleWorkout(env.DB,f.userId,f.session.id,input);
 const exported=await exportUserData(env.DB,f.userId);
 expect((exported?.training as {freestyle_workout_receipts: unknown[]}).freestyle_workout_receipts).toHaveLength(1);
 const result=await deleteUserAccount(env.DB,f.userId,undefined,crypto.randomUUID());
 expect(result).toMatchObject({ok:true});
 expect(await env.DB.prepare('SELECT id FROM users WHERE id=?').bind(f.userId).first()).toBeNull();
 expect((await env.DB.prepare('SELECT * FROM freestyle_workout_receipts WHERE user_id=?').bind(f.userId).all()).results).toHaveLength(0);
});

it('sync deltas carry the real freestyle generation and old set tombstones',async()=>{
 const f=await fixture();
 const planned=await getOrCreateSession(env.DB,f.userId,f.plan.id,'2026-09-22',null);
 const oldSet=await logSet(env.DB,f.userId,{id:crypto.randomUUID(),session_id:planned.id,
  exercise_id:'ex_bench',set_index:1,weight:100,reps:5,source:'ios'});
 const cursor=Date.now();
 await discardSession(env.DB,f.userId,planned.id,planned.attempt);
 const fresh=await startFreestyleSession(env.DB,f.userId,planned.date,planned.attempt);
 if(!('session' in fresh))throw Error(JSON.stringify(fresh));
 const liveSet=await log({...f,session:fresh.session!});
 await runWorkoutWriteStatement(env.DB,env.DB.prepare('UPDATE sessions SET updated_at=? WHERE id=?').bind(cursor+10,planned.id));
 await runWorkoutWriteStatement(env.DB,env.DB.prepare('UPDATE set_logs SET updated_at=? WHERE id=?').bind(cursor+10,oldSet.set.id));
 await runWorkoutWriteStatement(env.DB,env.DB.prepare('UPDATE set_logs SET updated_at=? WHERE id=?').bind(cursor+10,liveSet.set.id));
 const delta=await getState(env.DB,f.userId,0,cursor);
 expect(delta.sessions).toEqual([expect.objectContaining({id:planned.id,kind:'freestyle',status:'in_progress',attempt:1,workout_id:null})]);
 expect(delta.sets).toHaveLength(2);
 expect(delta.sets).toEqual(expect.arrayContaining([
  expect.objectContaining({id:oldSet.set.id,deleted_at:expect.any(Number)}),
  expect.objectContaining({id:liveSet.set.id,deleted_at:null}),
 ]));
 const full=await getState(env.DB,f.userId,0,0);
 expect(full.sessions.find(s=>s.id===planned.id)).toMatchObject({kind:'freestyle',status:'in_progress'});
 expect(full.sets.filter(s=>s.session_id===planned.id&&s.deleted_at===null)).toHaveLength(1);
});

it('plan rebuilds preserve tombstones when a planned date later becomes freestyle',async()=>{
 const f=await fixture();await discardSession(env.DB,f.userId,f.session.id,0);
 const tree={workouts:[{name:'Gym',exercises:[{exercise:'bench',target_sets:3,target_reps:5}]}]};
 const created=await updatePlanTree(env.DB,f.userId,tree);
 if(!('plan' in created))throw Error(JSON.stringify(created));
 const workout=created.plan.workouts[0]!;
 const planned=await getOrCreateSession(env.DB,f.userId,f.plan.id,'2026-09-22',workout.id);
 const logged=await logSet(env.DB,f.userId,{id:crypto.randomUUID(),session_id:planned.id,exercise_id:'ex_bench',
  template_exercise_id:workout.exercises[0]!.id,set_index:1,weight:100,reps:5,source:'ios'});
 await discardSession(env.DB,f.userId,planned.id,0);
 const free=await startFreestyleSession(env.DB,f.userId,planned.date,0);
 if(!('session' in free))throw Error(JSON.stringify(free));
 await patchSession(env.DB,f.userId,planned.id,{status:'completed'},1);
 expect(await updatePlanTree(env.DB,f.userId,tree)).toHaveProperty('plan');
 expect(await env.DB.prepare('SELECT deleted_at FROM set_logs WHERE id=?').bind(logged.set.id).first()).toEqual({deleted_at:expect.any(Number)});
});

it('plan rebuilds can remap a saved freestyle workout after its session is discarded',async()=>{
 const f=await fixture();await log(f);const input=await draft(f);
 await saveFreestyleWorkout(env.DB,f.userId,f.session.id,input);
 await discardSession(env.DB,f.userId,f.session.id,1);
 const rebuilt=await updatePlanTree(env.DB,f.userId,{workouts:[{name:input.name,
  exercises:[{exercise:'bench',target_sets:1,target_reps:5}]}]});
 expect(rebuilt).toHaveProperty('plan');
 if(!('plan' in rebuilt))throw Error(JSON.stringify(rebuilt));
 expect(await getOwnedSessionByDate(env.DB,f.userId,f.session.date))
  .toMatchObject({kind:'freestyle',status:'discarded',workout_id:rebuilt.plan.workouts[0]!.id});
});

it('saving history into a replacement plan keeps session ownership and workout deletion consistent',async()=>{
 const f=await fixture();await log(f);const input=await draft(f);
 await createPlan(env.DB,f.userId,'Replacement');
 const active=(await getPlanTree(env.DB,f.userId))!;
 const saved=await saveFreestyleWorkout(env.DB,f.userId,f.session.id,
  {...input,expected_plan_id:active.id,expected_version:active.version});
 expect(saved).toMatchObject({plan_id:active.id,session:{plan_id:active.id,workout_id:input.workout_id}});
 expect(await deleteWorkout(env.DB,f.userId,input.workout_id)).toBeTruthy();
 expect(await getOwnedSessionByDate(env.DB,f.userId,f.session.date))
  .toMatchObject({plan_id:active.id,workout_id:null,status:'completed'});
});

it.each(['draft','plan'])('returns a concurrently committed retry receipt before the %s preflight conflict',async boundary=>{
 const f=await fixture();await log(f);const input=await draft(f);
 let injected=false;
 let acknowledgement:Awaited<ReturnType<typeof saveFreestyleWorkout>>|undefined;
 function wrap(statement:D1PreparedStatement,query:string):D1PreparedStatement {
  return new Proxy(statement,{get(target,key){
   if(key==='bind')return (...args:unknown[])=>wrap(target.bind(...args),query);
   if(key==='first')return async (...args:Parameters<D1PreparedStatement['first']>)=>{
    const result=await target.first(...args);
    const match=boundary==='draft'?query.includes('SELECT request,response FROM freestyle_workout_receipts')
      :query.includes("SELECT * FROM plans WHERE user_id = ?1 AND status = 'active'");
    if(!injected&&match){
     injected=true;acknowledgement=await saveFreestyleWorkout(env.DB,f.userId,f.session.id,input);
     // Draft race returns the already-read missing receipt. Plan race reads
     // the new version that committed between source review and plan lookup.
     if(boundary==='plan')return target.first(...args);
    }
    return result;
   };
   const value=Reflect.get(target,key,target);return typeof value==='function'?value.bind(target):value;
  }});
 }
 const racing=new Proxy(env.DB,{get(target,key){
  if(key==='prepare')return (query:string)=>wrap(target.prepare(query),query);
  const value=Reflect.get(target,key,target);return typeof value==='function'?value.bind(target):value;
 }});
 const result=await saveFreestyleWorkout(racing,f.userId,f.session.id,input);
 expect(injected).toBe(true);expect(result).toEqual(acknowledgement);
 expect(result).toHaveProperty('workout_id',input.workout_id);
 expect((await getPlanTree(env.DB,f.userId))?.workouts).toHaveLength(1);
});

it.each(['omitted','duplicated','wrong source'])('rejects %s reviewed cohorts while allowing explicit target edits',async mode=>{
 const f=await fixture();await log(f,100,5);await log(f,120,3);const input=await draft(f);
 const slots=mode==='omitted'?[input.slots[0]!]:mode==='duplicated'?[input.slots[0]!,input.slots[0]!]
  :[{...input.slots[0]!,source_set_ids:[crypto.randomUUID()]},input.slots[1]!];
 expect(await saveFreestyleWorkout(env.DB,f.userId,f.session.id,{...input,slots})).toHaveProperty('error','invalid_fields');
 expect((await getPlanTree(env.DB,f.userId))?.version).toBe(f.plan.version);
 const edited={...input,slots:input.slots.map(s=>({...s,target_weight:90,target_sets:3,target_reps:8}))};
 expect(await saveFreestyleWorkout(env.DB,f.userId,f.session.id,edited)).toHaveProperty('workout_id',input.workout_id);
 expect((await getPlanTree(env.DB,f.userId))?.workouts[0]?.exercises).toHaveLength(2);
});

it('does not convert a rep-mode timed catalog log into an implicit timed prescription',async()=>{
 const f=await fixture();await log(f,0,12,{exercise_id:'ex_plank',is_timed:false});
 const input=await draft(f);expect(input.slots[0]!.target_duration_s).toBeNull();
 expect(await saveFreestyleWorkout(env.DB,f.userId,f.session.id,input))
  .toEqual({error:'invalid_fields',fields:['target_duration_s']});
 expect((await getPlanTree(env.DB,f.userId))?.version).toBe(f.plan.version);
});
