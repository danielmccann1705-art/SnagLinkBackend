import {productionContainerEnvironment, productionAPIOrigin, productionPortalOrigin} from './production-config.mjs';
import {backendRequest, privateResponse} from './proxy.mjs';

export async function productionResponse(request, env) {
  try { productionContainerEnvironment(env); }
  catch { return privateResponse(new Response('Snaglist is awaiting configuration.', {status: 503})); }
  const url = new URL(request.url);
  if (![productionAPIOrigin, productionPortalOrigin].includes(url.origin)) {
    return privateResponse(new Response('Open the Snaglist service address.', {status: 421}));
  }
  let path;
  try { path = '/' + decodeURIComponent(url.pathname).split('/').filter(Boolean).join('/').toLowerCase(); }
  catch { return privateResponse(new Response('Invalid address.', {status: 400})); }
  if (path === '/internal' || path.startsWith('/internal/')) {
    return privateResponse(new Response('Not found', {status: 404}));
  }
  // The released offline app does not require these legacy public uploads. Never
  // create new publicly readable photo/report objects on the unified platform.
  if (request.method === 'POST' && (path === '/api/v1/uploads/photo' ||
      /^\/api\/v1\/magic-links\/.+\/(photos|drawings|report)$/.test(path))) {
    return privateResponse(new Response(JSON.stringify({error: true,
      identifier: 'legacy_media_unavailable',
      reason: 'Update Snaglist to share securely. Your local work is kept.'}),
      {status: 503, headers: {'Content-Type': 'application/json'}}));
  }
  try {
    return privateResponse(await env.BACKEND.getByName('production').fetch(backendRequest(request)));
  } catch {
    return privateResponse(new Response('Snaglist could not complete the request. Please retry.', {status: 503}));
  }
}

export async function productionMaintenance(env, now = Date.now()) {
  const configured = productionContainerEnvironment(env);
  const response = await env.BACKEND.getByName('production').fetch(
    new Request('https://container.invalid/internal/maintenance/cleanup', {
      method: 'POST', headers: {Authorization: `Bearer ${configured.MAINTENANCE_SECRET}`, 'X-Forwarded-Proto': 'https'}
    }));
  // Mark the scheduled invocation as failed without copying private response bodies
  // to logs. A scheduler success is not evidence that cleanup actually ran.
  const failed = () => new Error('Scheduled Snaglist maintenance failed');
  if (!response.ok || !response.headers.get('Content-Type')?.toLowerCase().startsWith('application/json') ||
      !response.body || Number(response.headers.get('Content-Length') ?? 0) > 4096) throw failed();
  const reader = response.body.getReader();
  let size = 0;
  const chunks = [];
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 4096) { await reader.cancel(); throw failed(); }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const result = JSON.parse(new TextDecoder().decode(bytes));
    const last = typeof result.lastSuccessfulRun === 'string' ? Date.parse(result.lastSuccessfulRun) : NaN;
    // A skipped overlapping invocation is healthy only when a recent success is
    // recorded. This matches the backend's 26-hour overdue alert boundary.
    if (typeof result.ran !== 'boolean' || !Number.isFinite(last) ||
        last > now + 60_000 || now - last > 26 * 60 * 60_000) throw failed();
  } catch { throw failed(); }
  finally { reader.releaseLock(); }
}
