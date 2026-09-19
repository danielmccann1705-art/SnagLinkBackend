/** Internal DRA-03 storage adapter; no HTTP routes, parser, ACL or ready-state API.
 * Receives server-verified allocations and a current-authority callback. The
 * private R2 binding stays outside the untrusted one-job renderer container.
 */
const MIB = 1024 * 1024;
const NS = '266fb6c8-2b63-58a1-9a9d-5604571bb97d';
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const HASH = /^[a-f0-9]{64}$/;
const PROFILE = /^drawing-linux-byte-v1:[a-f0-9]{64}$/;
const enc = new TextEncoder();
const hex = value => [...new Uint8Array(value)].map(b => b.toString(16).padStart(2, '0')).join('');
const bytes = value => new Uint8Array(value.match(/../g).map(h => parseInt(h, 16)));

export class DrawingStoreError extends Error {
  constructor(code) { super(code); this.name = 'DrawingStoreError'; this.code = code; }
}
function requireThat(ok, code) { if (!ok) throw new DrawingStoreError(code); }
function exactKeys(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).sort().join('|') === [...keys].sort().join('|');
}
function sized(value, maximum) { return Number.isSafeInteger(value) && value > 0 && value <= maximum; }

export async function drawingPageID(assetID, index, subtle = globalThis.crypto.subtle) {
  requireThat(typeof assetID === 'string' && UUID.test(assetID) && Number.isInteger(index) && index >= 0 && index < 100, 'drawing_identity_invalid');
  const namespace = bytes(NS.replaceAll('-', ''));
  const name = enc.encode(`${assetID.toLowerCase()}:${index}`);
  const input = new Uint8Array(namespace.length + name.length);
  input.set(namespace); input.set(name, namespace.length);
  const digest = new Uint8Array(await subtle.digest('SHA-1', input)).slice(0, 16);
  digest[6] = (digest[6] & 15) | 80; digest[8] = (digest[8] & 63) | 128;
  const h = hex(digest);
  return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`.toUpperCase();
}

/** Factories are explicit for tests; production defaults are documented Workers
 * DigestStream and FixedLengthStream APIs, not buffered whole-PDF hashing.
 */
export function createDrawingStore({ bucket, processorProfile, writeIntents,
  digestStream = () => new globalThis.crypto.DigestStream('SHA-256'),
  fixedLengthStream = size => new globalThis.FixedLengthStream(size),
  subtle = globalThis.crypto.subtle }) {
  requireThat(typeof processorProfile === 'string' && PROFILE.test(processorProfile), 'drawing_profile_unavailable');
  requireThat(bucket && typeof bucket.get === 'function' && typeof bucket.put === 'function', 'drawing_storage_unavailable');
  const plans = new WeakSet();

  function allocation(value) {
    requireThat(exactKeys(value, ['workspaceId','projectId','assetId','purpose','sha256','byteCount','mimeType','processorProfile']), 'drawing_allocation_invalid');
    requireThat(['workspaceId','projectId','assetId'].every(k => typeof value[k] === 'string' && UUID.test(value[k])), 'drawing_identity_invalid');
    requireThat(value.purpose === 'drawing_source' && value.processorProfile === processorProfile && typeof value.sha256 === 'string' && HASH.test(value.sha256), 'drawing_allocation_invalid');
    requireThat(typeof value.mimeType === 'string','drawing_allocation_invalid');
    const maximum = { 'application/pdf': 50*MIB, 'image/jpeg': 10*MIB, 'image/png': 10*MIB }[value.mimeType];
    requireThat(maximum && sized(value.byteCount, maximum), 'drawing_allocation_invalid');
    return Object.freeze({ ...value, workspaceId:value.workspaceId.toUpperCase(), projectId:value.projectId.toUpperCase(), assetId:value.assetId.toUpperCase() });
  }
  function plan(source, suffix, sha256, byteCount, mimeType, kind) {
    const value = Object.freeze({ source, key:`drawings/${source.workspaceId}/${source.projectId}/${source.assetId}/${suffix}`, sha256, byteCount, mimeType, kind });
    plans.add(value); return value;
  }
  function original(value) {
    const source = allocation(value);
    return plan(source, 'original', source.sha256, source.byteCount, source.mimeType, 'original');
  }
  async function pageObjects(value, manifest) {
    const source = allocation(value);
    requireThat(exactKeys(manifest, ['sourceSHA256','sourceBytes','sourceMIME','processorProfile','pages']) &&
      manifest.sourceSHA256 === source.sha256 && manifest.sourceBytes === source.byteCount &&
      manifest.sourceMIME === source.mimeType && manifest.processorProfile === source.processorProfile &&
      Array.isArray(manifest.pages) && manifest.pages.length >= 1 && manifest.pages.length <= 100 &&
      (source.mimeType === 'application/pdf' || manifest.pages.length === 1), 'drawing_manifest_invalid');
    requireThat(manifest.pages.every(p => p && typeof p === 'object' && !Array.isArray(p)), 'drawing_manifest_invalid');
    const pages = [...manifest.pages].sort((a,b) => a.sourcePageIndex-b.sourcePageIndex);
    let total = 0;
    // Geometry is deliberately not accepted/attested here. The server's existing
    // DrawingGeometryValidation must run before readiness or publication.
    for (const [index,p] of pages.entries()) {
      requireThat(exactKeys(p, ['sourcePageIndex','sourcePageLabel','geometry','renditionSHA256','renditionBytes','thumbnailSHA256','thumbnailBytes']) &&
        Number.isInteger(p.sourcePageIndex) && p.sourcePageIndex === index &&
        typeof p.renditionSHA256 === 'string' && typeof p.thumbnailSHA256 === 'string' && HASH.test(p.renditionSHA256) && HASH.test(p.thumbnailSHA256) &&
        sized(p.renditionBytes,10*MIB) && sized(p.thumbnailBytes,10*MIB), 'drawing_manifest_invalid');
      total += p.renditionBytes + p.thumbnailBytes;
    }
    requireThat(total <= 256*MIB, 'drawing_output_limit');
    const objects = [];
    for (const p of pages) {
      const id = await drawingPageID(source.assetId,p.sourcePageIndex,subtle);
      objects.push(plan(source,`pages/${id}/${p.renditionSHA256}.jpg`,p.renditionSHA256,p.renditionBytes,'image/jpeg','rendition'));
      objects.push(plan(source,`pages/${id}/thumb-${p.thumbnailSHA256}.jpg`,p.thumbnailSHA256,p.thumbnailBytes,'image/jpeg','thumbnail'));
    }
    return Object.freeze(objects);
  }
  function own(value) { requireThat(plans.has(value), 'drawing_object_plan_invalid'); }
  async function authority(value, gate, phase, signal) {
    own(value);
    requireThat(!signal?.aborted, 'drawing_operation_cancelled');
    requireThat(typeof gate === 'function', 'drawing_authority_required');
    try { await gate({ source:value.source, phase }); }
    catch { throw new DrawingStoreError('drawing_authority_changed'); }
    requireThat(!signal?.aborted, 'drawing_operation_cancelled');
  }
  async function fingerprint(body, expected, signal) {
    requireThat(body && typeof body.getReader === 'function', 'drawing_object_missing');
    const reader = body.getReader(), digest = digestStream(), writer = digest.getWriter();
    void digest.digest.catch(()=>{});
    let count = 0;
    const cancelled = () => { void reader.cancel().catch(()=>{}); void writer.abort().catch(()=>{}); };
    signal?.addEventListener('abort',cancelled,{once:true});
    try {
      while (true) {
        requireThat(!signal?.aborted,'drawing_operation_cancelled');
        const part = await reader.read(); if (part.done) break;
        requireThat(part.value instanceof Uint8Array,'drawing_object_invalid');
        count += part.value.byteLength;
        requireThat(count <= expected.byteCount,'drawing_object_identity_mismatch');
        await writer.write(part.value);
      }
      requireThat(count === expected.byteCount,'drawing_object_identity_mismatch');
      await writer.close();
      requireThat(hex(await digest.digest) === expected.sha256,'drawing_object_identity_mismatch');
      return { byteCount:count, sha256:expected.sha256 };
    } catch (error) {
      if (error instanceof DrawingStoreError) throw error;
      throw new DrawingStoreError(signal?.aborted ? 'drawing_operation_cancelled' : 'drawing_storage_read_failed');
    } finally {
      signal?.removeEventListener('abort',cancelled);
      await reader.cancel().catch(()=>{}); reader.releaseLock();
      await writer.abort().catch(()=>{}); writer.releaseLock();
      void digest.digest.catch(()=>{});
    }
  }
  async function readback(value, gate, phase, signal, permitMissing = false) {
    await authority(value,gate,phase,signal);
    let object;
    try { object = await bucket.get(value.key); }
    catch { throw new DrawingStoreError('drawing_storage_unavailable'); }
    if (!object) {
      requireThat(permitMissing,'drawing_object_missing');
      return null;
    }
    if (object.size !== value.byteCount || object.httpMetadata?.contentType !== value.mimeType) {
      await object.body?.cancel().catch(()=>{});
      throw new DrawingStoreError('drawing_object_identity_mismatch');
    }
    const result = await fingerprint(object.body,value,signal);
    await authority(value,gate,'after-readback',signal);
    return result;
  }
  async function putVerified(value, body, { assertCurrent, signal } = {}) {
    own(value);
    requireThat(body && typeof body.getReader === 'function','drawing_source_stream_invalid');
    let existing;
    try { existing = await readback(value,assertCurrent,'before-write',signal,true); }
    catch (error) { await body.cancel().catch(()=>{}); throw error; }
    if (existing) {
      await body.cancel().catch(()=>{});
      return Object.freeze({ ...existing, reused:true, verification:'object-bytes-only' });
    }
    // This adapter is injected by the authenticated server bridge. It must
    // persist the exact plan under fresh authority before allowing external IO.
    // There is deliberately no default and no lease-expiry success fallback.
    if (!writeIntents || ['begin','settle','uncertain'].some(name => typeof writeIntents[name] !== 'function')) {
      await body.cancel().catch(()=>{});
      throw new DrawingStoreError('drawing_write_intent_required');
    }
    // Complete local stream setup before durable admission. Constructor/lock
    // failures cannot issue a PUT and must not strand a pending intent.
    let fixed, writer, reader;
    try {
      fixed = fixedLengthStream(value.byteCount);
      writer = fixed.writable.getWriter(); reader = body.getReader();
    } catch {
      await Promise.allSettled([body.cancel(),fixed?.readable.cancel(),writer?.abort()]);
      writer?.releaseLock();
      throw new DrawingStoreError('drawing_source_stream_invalid');
    }
    let written = 0;
    // A conditional R2 PUT may reject an existing key without ever consuming
    // the fixed-length stream. Cancel its readable side as well: otherwise a
    // pending backpressured writer.write can keep writer.abort waiting forever.
    const cancel = async () => { await Promise.allSettled([
      reader.cancel(), fixed.readable.cancel(), writer.abort()
    ]); };
    let writeTicket;
    try { writeTicket = await writeIntents.begin(value); }
    catch {
      await cancel(); reader.releaseLock(); writer.releaseLock();
      throw new DrawingStoreError('drawing_write_intent_unavailable');
    }
    const onAbort = () => { void cancel(); };
    signal?.addEventListener('abort',onAbort,{once:true});
    const pump = (async () => {
      while (true) {
        requireThat(!signal?.aborted,'drawing_operation_cancelled');
        const part = await reader.read(); if (part.done) break;
        requireThat(part.value instanceof Uint8Array,'drawing_source_stream_invalid');
        written += part.value.byteLength;
        requireThat(written <= value.byteCount,'drawing_source_identity_mismatch');
        await writer.write(part.value);
      }
      requireThat(written === value.byteCount,'drawing_source_identity_mismatch');
      await writer.close();
    })().catch(async error => { await writer.abort().catch(()=>{}); throw error; });
    void pump.catch(()=>{});
    let result;
    try {
      // A concurrent same-key write cannot overwrite an existing original/page.
      // R2 verifies the supplied SHA-256 against the incoming streamed bytes.
      result = await bucket.put(value.key,fixed.readable,{
        onlyIf:new Headers({'If-None-Match':'*'}),sha256:bytes(value.sha256).buffer,
        httpMetadata:{contentType:value.mimeType,cacheControl:'private, no-store'},
        customMetadata:{purpose:'drawing_source',processorProfile:value.source.processorProfile}
      });
      if (result === null) await cancel();
      else await pump;
    } catch (error) {
      await cancel();
      // An unavailable settlement service leaves its durable active record.
      // Remote ambiguity remains pending even if this local operation aborts.
      await writeIntents.uncertain(writeTicket).catch(()=>{});
      if (signal?.aborted) throw new DrawingStoreError('drawing_operation_cancelled');
      if (error instanceof DrawingStoreError) throw error;
      throw new DrawingStoreError('drawing_storage_write_failed');
    } finally {
      await cancel(); await pump.catch(()=>{});
      signal?.removeEventListener('abort',onAbort);
      reader.releaseLock(); writer.releaseLock();
    }
    try { await writeIntents.settle(writeTicket); }
    catch { throw new DrawingStoreError('drawing_write_intent_unavailable'); }
    const checked = await readback(value,assertCurrent,'after-write',signal);
    return Object.freeze({ ...checked,reused:result===null,verification:'object-bytes-only' });
  }
  return Object.freeze({ original,pageObjects,putVerified,
    verify: (value,options={}) => readback(value,options.assertCurrent,'before-readback',options.signal) });
}
