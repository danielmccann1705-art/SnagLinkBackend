// The isolated unified candidate has private storage. Historical v1 uploads
// advertise public object URLs, so reject them before any S3 or database write.
// The recovery deployment and canonical/private v2 routes remain unchanged.
export function legacyCandidateResponse(request, env) {
  if (env.STAGING_DEPLOYMENT !== 'unified-candidate' || request.method !== 'POST') return null;
  let path;
  try {
    path = '/' + decodeURIComponent(new URL(request.url).pathname)
      .split('/').filter(Boolean).join('/').toLowerCase();
  } catch {
    return null; // Invalid paths are left to the normal router; no new bypass.
  }
  const upload = path === '/api/v1/uploads/photo';
  const syncedEvidence = /^\/api\/v1\/magic-links\/.+\/(photos|drawings|report)$/.test(path);
  if (!upload && !syncedEvidence) return null;
  return new Response(JSON.stringify({
    error: true,
    identifier: 'legacy_media_unavailable_in_candidate',
    reason: 'This staging service cannot accept photo or report uploads from this app version. Keep your local evidence.'
  }), {status:503, headers:{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'}});
}
