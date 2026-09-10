import test from 'node:test';
import assert from 'node:assert/strict';
import {backendRequest, privateResponse} from '../src/proxy.mjs';

test('proxy preserves link paths, auth, session cookies and upload bytes', async () => {
  const request = new Request('https://stage.example/m/synthetic-link/complete?snag=synthetic', {
    method:'POST', body:new Uint8Array([0,255,10,128]),
    headers:{'Authorization':'Bearer synthetic', 'Cookie':'session=synthetic',
      'X-Session-Token':'synthetic-token', 'Content-Type':'application/octet-stream',
      'X-Forwarded-For':'spoofed', 'X-Real-IP':'spoofed', 'Forwarded':'for=spoofed',
      'CF-Connecting-IP':'192.0.2.10'}
  });
  const forwarded=backendRequest(request);
  assert.equal(forwarded.url,request.url);
  assert.equal(forwarded.method,'POST');
  assert.equal(forwarded.headers.get('Authorization'),'Bearer synthetic');
  assert.equal(forwarded.headers.get('Cookie'),'session=synthetic');
  assert.equal(forwarded.headers.get('X-Session-Token'),'synthetic-token');
  assert.equal(forwarded.headers.get('X-Forwarded-For'),'192.0.2.10');
  assert.equal(forwarded.headers.get('Forwarded'),null);
  assert.deepEqual(new Uint8Array(await forwarded.arrayBuffer()),new Uint8Array([0,255,10,128]));
});
test('missing edge address cannot leave spoofed proxy headers', () => {
  const forwarded=backendRequest(new Request('https://stage.example/health',{
    headers:{'X-Forwarded-For':'spoofed','X-Real-IP':'spoofed'}
  }));
  assert.equal(forwarded.headers.get('X-Forwarded-For'),null);
  assert.equal(forwarded.headers.get('X-Real-IP'),null);
});
test('redirects and secure session cookies survive without caching private links', () => {
  const response=privateResponse(new Response(null,{status:303,headers:{
    Location:'/m/synthetic-link', 'Set-Cookie':'session=synthetic; Secure; HttpOnly; SameSite=Lax',
    'Cache-Control':'public, max-age=3600'
  }}));
  assert.equal(response.status,303);
  assert.equal(response.headers.get('Location'),'/m/synthetic-link');
  assert.match(response.headers.get('Set-Cookie'),/Secure; HttpOnly/);
  assert.equal(response.headers.get('Cache-Control'),'no-store');
  assert.equal(response.headers.get('Referrer-Policy'),'no-referrer');
});
