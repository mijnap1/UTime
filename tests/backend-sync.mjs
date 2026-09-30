// Run with: node --experimental-strip-types tests/backend-sync.mjs
import assert from 'node:assert/strict';
let handler;
globalThis.Deno = { serve: fn => { handler = fn; }, env: { get: () => 'test-only' } };
const { sendAPNs, updateActiveLiveActivities, startDueSchedules } = await import('../supabase/functions/process-live-activities/index.ts');
const calls = [];
globalThis.fetch = async url => {
 calls.push(String(url));
 return calls.length === 1 ? Response.json({reason:'BadDeviceToken'},{status:400}) : new Response(null,{status:200});
};
assert.equal((await sendAPNs('api.push.apple.com','fake',{})).status,200);
assert.match(calls[1],/api\.sandbox\.push/);
calls.length = 0;
globalThis.fetch = async url => { calls.push(String(url)); return Response.json({reason:'ExpiredProviderToken'},{status:403}); };
assert.equal((await sendAPNs('api.push.apple.com','fake',{})).status,403);
assert.equal(calls.length,1);
// A broken activity must not abort the batch. Invalid key makes both attempts fail, independently.
const rows = ['first','second'].map(activity_id => ({activity_id, start_time:'2020-01-01',end_time:'2020-01-02'}));
globalThis.fetch = async () => Response.json(rows);
const result = await updateActiveLiveActivities({supabaseUrl:'https://test.invalid',secretKey:'test',apnsPrivateKey:'invalid'},new Date());
assert.equal(result.failed,2);
// One rejected start must not prevent a later device from receiving its start.
const key = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
const pem = Buffer.from(await crypto.subtle.exportKey('pkcs8',key.privateKey)).toString('base64');
const config = {supabaseUrl:'https://test.invalid',secretKey:'test',apnsPrivateKey:pem,
 apnsHost:'api.push.apple.com',apnsTeamID:'test',apnsKeyID:'test',apnsTopic:'test'};
const starts = ['broken','healthy'].map(id => ({id,install_id:id,push_stage:'pending',course_code:'TEST',
 start_time:'2099-01-01T09:00:00Z',end_time:'2099-01-01T10:00:00Z',alert_cue_minutes:5}));
const delivered = [];
globalThis.fetch = async (url,options={}) => {
 const value = String(url);
 if (value.includes('/rpc/due_class_schedules')) return Response.json(starts);
 if (value.includes('/push_to_start_tokens')) return Response.json([{push_to_start_token:value.includes('broken')?'broken':'healthy'}]);
 if (value.includes('/3/device/')) {
  if (value.endsWith('/broken')) return Response.json({reason:'BadDeviceToken'},{status:400});
  delivered.push(value); return new Response(null,{status:200});
 }
 return options.method === 'PATCH' ? new Response(null,{status:204}) : Response.json([]);
};
assert.deepEqual(await startDueSchedules(config,new Date()),{checked:2,started:1,skipped:0,failed:1});
assert.equal(delivered.length,1);
await import('../supabase/functions/sync-schedule/index.ts');
let writes = [];
globalThis.fetch = async (url, options) => { writes.push([String(url),options]); return Response.json(1); };
const valid = { install_id:'test-install',live_activity_lead_minutes:30,alert_cue_minutes:5,events:[{event_uid:'event',course_code:'CSC',start_time:'2099-01-01T09:00:00Z',end_time:'2099-01-01T10:00:00Z'}] };
const request = data => new Request('https://test.invalid',{method:'POST',body:JSON.stringify(data)});
assert.equal((await handler(request(valid))).status,200);
assert.equal(writes.length,1);
assert.match(writes[0][0],/rpc\/sync_class_schedule$/);
assert.equal(writes[0][1].method,'POST');
writes=[];
assert.equal((await handler(request({...valid,events:[...valid.events,...valid.events]}))).status,400);
assert.equal(writes.length,0);
assert.equal((await handler(request(null))).status,400);
globalThis.fetch = async () => new Response(null,{status:500});
assert.equal((await handler(request(valid))).status,500);
console.log('Backend checks passed: environment fallback, per-device isolation, atomic RPC, validation, sync failure.');
