import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { createDrawingStore, drawingPageID, DrawingStoreError } from '../drawing-store.mjs';

const PROFILE = 'drawing-linux-byte-v1:0c398d19456a85be07a4999a8a40e30cbcddb5ebde3f2da8f9114fb028f04fcc';
const SOURCE = Buffer.from('%PDF-1.7\nSynthetic single-job storage fixture.\n%%EOF');
const hash = data => createHash('sha256').update(data).digest('hex');
const ALLOCATION = Object.freeze({ workspaceId:'a1111111-1111-4111-8111-111111111111',
  projectId:'b2222222-2222-4222-8222-222222222222',assetId:'c3333333-3333-4333-8333-333333333333',
  purpose:'drawing_source',sha256:hash(SOURCE),byteCount:SOURCE.length,mimeType:'application/pdf',processorProfile:PROFILE });

function stream(data, { step=7, onCancel=()=>{}, onRead=()=>{} }={}) {
  let position=0;
  return new ReadableStream({ pull(controller) {
    onRead();
    if(position===data.length) { controller.close(); return; }
    const end=Math.min(data.length,position+step);
    controller.enqueue(new Uint8Array(data.subarray(position,end))); position=end;
  }, cancel:onCancel }, {highWaterMark:0});
}
function digestStream() {
  const hash=createHash('sha256'); let resolve,reject;
  const digest=new Promise((yes,no)=>{resolve=yes;reject=no;});
  void digest.catch(()=>{});
  const writable=new WritableStream({write(data){hash.update(data);},close(){resolve(hash.digest());},abort(error){reject(error);}});
  writable.digest=digest; return writable;
}
function fixedLengthStream(length) {
  let bytes=0;
  return new TransformStream({transform(chunk,controller){
    bytes+=chunk.byteLength; if(bytes>length) throw Error('fixed overflow'); controller.enqueue(chunk);
  },flush(){if(bytes!==length) throw Error('fixed underflow');}});
}
class Bucket {
  objects=new Map(); writes=0; reads=0; onPut;
  seed(key,data,mime='application/pdf') { this.objects.set(key,{data:Buffer.from(data),mime}); }
  async get(key) {
    this.reads++; const value=this.objects.get(key); if(!value)return null;
    return {size:value.declaredSize??value.data.length,httpMetadata:{contentType:value.mime},body:stream(value.data)};
  }
  async put(key,body,options) {
    this.writes++;
    assert.equal(options.onlyIf.get('If-None-Match'),'*');
    assert.equal(options.httpMetadata.cacheControl,'private, no-store');
    assert.equal(options.customMetadata.purpose,'drawing_source');
    assert.equal(options.customMetadata.processorProfile,PROFILE);
    if(this.onPut) await this.onPut(key);
    if(this.objects.has(key)) return null;
    const reader=body.getReader(),chunks=[];
    try { while(true){const part=await reader.read();if(part.done)break;chunks.push(Buffer.from(part.value));} }
    finally { reader.releaseLock(); }
    const data=Buffer.concat(chunks);
    if(hash(data)!==Buffer.from(options.sha256).toString('hex')) throw Error('SYNTHETIC_PROVIDER_DETAIL_MUST_NOT_LEAK');
    this.seed(key,data,options.httpMetadata.contentType);
    return {size:data.length};
  }
}
function fixture() {
  const bucket=new Bucket();
  const store=createDrawingStore({bucket,processorProfile:PROFILE,digestStream,fixedLengthStream,subtle:webcrypto.subtle});
  return {bucket,store,original:store.original(ALLOCATION)};
}
const permit=async()=>{};
const rejectsCode=(promise,code)=>assert.rejects(promise,e=>e instanceof DrawingStoreError&&e.code===code);

test('writes source through checksum-checked conditional PUT then hashes actual readback',async()=>{
  const {store,bucket,original}=fixture();
  assert.equal(original.key,'drawings/A1111111-1111-4111-8111-111111111111/B2222222-2222-4222-8222-222222222222/C3333333-3333-4333-8333-333333333333/original');
  const phases=[];
  const result=await store.putVerified(original,stream(SOURCE),{assertCurrent:async({source,phase})=>{assert.equal(source.projectId,ALLOCATION.projectId.toUpperCase());phases.push(phase);}});
  assert.deepEqual(result,{byteCount:SOURCE.length,sha256:hash(SOURCE),reused:false,verification:'object-bytes-only'});
  assert.deepEqual(phases,['before-write','after-write','after-readback']);
  assert.equal(bucket.writes,1);assert.equal(bucket.reads,2);
  assert.equal('key' in result,false);assert.equal('ready' in result,false);
});

test('idempotent retry verifies stored bytes, cancels duplicate input and does not overwrite',async()=>{
  const {store,bucket,original}=fixture();bucket.seed(original.key,SOURCE);
  let cancelled=false,read=false;
  const result=await store.putVerified(original,stream(SOURCE,{onCancel:()=>{cancelled=true;},onRead:()=>{read=true;}}),{assertCurrent:permit});
  assert.equal(result.reused,true);assert.equal(bucket.writes,0);assert.equal(cancelled,true);assert.equal(read,false);
});

test('parallel matching original writer remains a safe retry without overwriting',async()=>{
  const {store,bucket,original}=fixture();bucket.onPut=async key=>bucket.seed(key,SOURCE);
  const result=await store.putVerified(original,stream(SOURCE),{assertCurrent:permit});
  assert.equal(result.reused,true);assert.deepEqual(bucket.objects.get(original.key).data,SOURCE);
});

test('parallel different original writer is retained and rejected, never deleted/repaired',async()=>{
  const {store,bucket,original}=fixture();const different=Buffer.alloc(SOURCE.length,65);
  bucket.onPut=async key=>bucket.seed(key,different);
  await rejectsCode(store.putVerified(original,stream(SOURCE),{assertCurrent:permit}),'drawing_object_identity_mismatch');
  assert.deepEqual(bucket.objects.get(original.key).data,different);
});

test('wrong incoming source hash cannot commit and provider diagnostics stay private',async()=>{
  const {store,bucket,original}=fixture();
  await rejectsCode(store.putVerified(original,stream(Buffer.alloc(SOURCE.length,66)),{assertCurrent:permit}),'drawing_storage_write_failed');
  assert.equal(bucket.objects.size,0);
});

for(const delta of [-1,1]) test(`truncated/overlong stream (${delta}) never commits`,async()=>{
  const {store,bucket,original}=fixture();
  await assert.rejects(store.putVerified(original,stream(Buffer.alloc(SOURCE.length+delta,67)),{assertCurrent:permit}),DrawingStoreError);
  assert.equal(bucket.objects.size,0);
});

for(const mode of ['missing','metadata-size','metadata-mime','actual-hash','actual-short','actual-long']) test(`readback detects ${mode}`,async()=>{
  const {store,bucket,original}=fixture();
  if(mode!=='missing') {
    bucket.seed(original.key,SOURCE);
    const value=bucket.objects.get(original.key);
    if(mode==='metadata-size')value.declaredSize=SOURCE.length+1;
    if(mode==='metadata-mime')value.mime='image/jpeg';
    if(mode==='actual-hash')value.data=Buffer.alloc(SOURCE.length,68);
    if(mode==='actual-short'){value.data=SOURCE.subarray(0,-1);value.declaredSize=SOURCE.length;}
    if(mode==='actual-long'){value.data=Buffer.concat([SOURCE,Buffer.from('x')]);value.declaredSize=SOURCE.length;}
  }
  await rejectsCode(store.verify(original,{assertCurrent:permit}),mode==='missing'?'drawing_object_missing':'drawing_object_identity_mismatch');
});

test('missing or revoked authority blocks before storage; guessed plans are not accepted',async()=>{
  const {store,bucket,original}=fixture();
  await rejectsCode(store.verify(original),'drawing_authority_required');
  await rejectsCode(store.verify(original,{assertCurrent:async()=>{throw Error('removed member');}}),'drawing_authority_changed');
  await rejectsCode(store.verify({...original},{assertCurrent:permit}),'drawing_object_plan_invalid');
  assert.equal(bucket.reads,0);assert.equal(bucket.writes,0);
});

test('lease replacement/access removal after slow upload prevents success',async()=>{
  const {store,bucket,original}=fixture();
  await rejectsCode(store.putVerified(original,stream(SOURCE),{assertCurrent:async({phase})=>{
    if(phase==='after-write')throw Error('lease replaced');
  }}),'drawing_authority_changed');
  assert.deepEqual(bucket.objects.get(original.key).data,SOURCE); // private orphan, no ready receipt
});

test('access removal during readback prevents the verified receipt',async()=>{
  const {store,bucket,original}=fixture();bucket.seed(original.key,SOURCE);
  await rejectsCode(store.verify(original,{assertCurrent:async({phase})=>{if(phase==='after-readback')throw Error('removed');}}),'drawing_authority_changed');
});

test('aborted operation returns no bytes or receipt',async()=>{
  const {store,bucket,original}=fixture();const stop=new AbortController();stop.abort();
  await rejectsCode(store.putVerified(original,stream(SOURCE),{assertCurrent:permit,signal:stop.signal}),'drawing_operation_cancelled');
  assert.equal(bucket.writes,0);assert.equal(bucket.reads,0);
});

test('aborting an in-flight write cancels the input and returns no receipt',async()=>{
  const {store,bucket,original}=fixture();const stop=new AbortController();let cancelled=false;
  const input=stream(SOURCE,{onRead:()=>stop.abort(),onCancel:()=>{cancelled=true;}});
  await rejectsCode(store.putVerified(original,input,{assertCurrent:permit,signal:stop.signal}),'drawing_operation_cancelled');
  assert.equal(cancelled,true);assert.equal(bucket.objects.size,0);
});

test('private storage read failures are sanitized, including errors from streamed bodies',async()=>{
  const {store,bucket,original}=fixture();
  bucket.get=async()=>{throw Error('SYNTHETIC_PROVIDER_SECRET');};
  await rejectsCode(store.verify(original,{assertCurrent:permit}),'drawing_storage_unavailable');
  bucket.get=async()=>({size:SOURCE.length,httpMetadata:{contentType:'application/pdf'},
    body:new ReadableStream({pull(){throw Error('SYNTHETIC_PROVIDER_SECRET');}})});
  await rejectsCode(store.verify(original,{assertCurrent:permit}),'drawing_storage_read_failed');
});

test('denied authority cancels caller upload input without reading or storing it',async()=>{
  const {store,bucket,original}=fixture();let cancelled=false,read=false;
  await rejectsCode(store.putVerified(original,stream(SOURCE,{onRead:()=>{read=true;},onCancel:()=>{cancelled=true;}}),
    {assertCurrent:async()=>{throw Error('wrong account');}}),'drawing_authority_changed');
  assert.equal(cancelled,true);assert.equal(read,false);assert.equal(bucket.reads,0);assert.equal(bucket.writes,0);
});

test('drawing purpose, source sizes, scope, keys and profiles are closed input domains',()=>{
  const {store}=fixture();
  for(const patch of [{purpose:'completion'},{purpose:'capture'},{processorProfile:'drawing-initial-v1'},
    {mimeType:'text/html'},{mimeType:['application/pdf']},{sha256:[ALLOCATION.sha256]},{byteCount:50*1024*1024+1},
    {byteCount:10*1024*1024+1,mimeType:'image/png'},{assetId:'../other'},{projectId:'https://example.test'},
    {key:'platform/escape'},{originalFilename:'caller.pdf'}]) {
    assert.throws(()=>store.original({...ALLOCATION,...patch}),DrawingStoreError);
  }
  assert.throws(()=>createDrawingStore({bucket:new Bucket(),processorProfile:'drawing-initial-v1'}),DrawingStoreError);
});

function manifest() { return {sourceSHA256:ALLOCATION.sha256,sourceBytes:ALLOCATION.byteCount,sourceMIME:ALLOCATION.mimeType,
  processorProfile:PROFILE,pages:[{sourcePageIndex:0,sourcePageLabel:'1',geometry:{notValidatedHere:true},
    renditionSHA256:hash(Buffer.from('page')),renditionBytes:4,thumbnailSHA256:hash(Buffer.from('thumb')),thumbnailBytes:5}]}; }

test('page IDs match backend UUIDv5 and uppercase key convention; geometry is not falsely attested',async()=>{
  const {store}=fixture(),m=manifest();const id=await drawingPageID(ALLOCATION.assetId,0,webcrypto.subtle);
  assert.equal(id,'89ECBFB9-10B0-56C3-8A6E-73A2B3A073D3');
  const objects=await store.pageObjects(ALLOCATION,m);
  assert.equal(objects.length,2);assert.equal(objects[0].mimeType,'image/jpeg');
  assert.ok(objects[0].key.endsWith(`/pages/${id}/${m.pages[0].renditionSHA256}.jpg`));
  assert.ok(objects[1].key.endsWith(`/pages/${id}/thumb-${m.pages[0].thumbnailSHA256}.jpg`));
  assert.equal(Object.isFrozen(objects),true);assert.equal(Object.isFrozen(objects[0]),true);
});

test('whole output identity is checked before returning any object plans',async()=>{
  const {store}=fixture();
  for(const patch of [{sourceSHA256:'a'.repeat(64)},{sourceBytes:1},{sourceMIME:'image/png'},
    {processorProfile:'drawing-initial-v1'},{pages:[]},{pages:[null]},{pages:[...manifest().pages,...manifest().pages]}]) {
    await rejectsCode(store.pageObjects(ALLOCATION,{...manifest(),...patch}),'drawing_manifest_invalid');
  }
  const tooMany=manifest();tooMany.pages=Array.from({length:14},(_,i)=>({...tooMany.pages[0],sourcePageIndex:i,renditionBytes:10*1024*1024,thumbnailBytes:10*1024*1024}));
  await rejectsCode(store.pageObjects(ALLOCATION,tooMany),'drawing_output_limit');
});

test('page bytes use immutable purpose-specific keys and are read back before acknowledgement',async()=>{
  const {store,bucket}=fixture(),objects=await store.pageObjects(ALLOCATION,manifest());
  for(const [i,object] of objects.entries()) {
    const result=await store.putVerified(object,stream(Buffer.from(i===0?'page':'thumb')),{assertCurrent:permit});
    assert.equal(result.verification,'object-bytes-only');assert.equal(result.reused,false);
  }
  assert.equal(bucket.objects.size,2);assert.equal([...bucket.objects.keys()].some(k=>k.startsWith('platform/')),false);
});
