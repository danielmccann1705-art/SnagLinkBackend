import {earlyUploadHeader} from './early-upload.mjs';

// `earlyUpload` is the Worker's own early-upload decision (early-upload.mjs): the header is always removed from what the
// caller sent and set only from it, so no request can turn the switch on for itself.
/** @param {Request} request @param {string | null} [earlyUpload] @returns {Request} */
export function backendRequest(request, earlyUpload = null) {
  const headers = new Headers(request.headers);
  headers.delete(earlyUploadHeader);
  if (earlyUpload) headers.set(earlyUploadHeader, earlyUpload);
  // Vapor reads X-Forwarded-For first. Replace caller-supplied proxy headers
  // with the address Cloudflare supplies to this Worker.
  const clientIP = headers.get('CF-Connecting-IP');
  headers.delete('Forwarded');
  headers.delete('X-Forwarded-For');
  headers.delete('X-Real-IP');
  if (clientIP) {
    headers.set('X-Forwarded-For', clientIP);
    headers.set('X-Real-IP', clientIP);
  }
  headers.set('X-Forwarded-Proto', 'https');
  return new Request(request, {headers});
}

export function privateResponse(response) {
  const headers = new Headers(response.headers);
  headers.set('Cache-Control', 'no-store');
  headers.set('Referrer-Policy', 'no-referrer');
  headers.set('X-Robots-Tag', 'noindex, nofollow');
  return new Response(response.body, {status: response.status, headers});
}
