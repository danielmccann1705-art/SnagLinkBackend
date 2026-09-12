import test from 'node:test';
import assert from 'node:assert/strict';
import {portalResponse,portalOrigin} from '../src/portal-proxy.mjs';

const env=(backend=async()=>new Response('api'))=>({STAGING_PORTAL_ENABLED:'true',PORTAL_ORIGIN:portalOrigin,
  BACKEND:{fetch:backend},ASSETS:{fetch:async()=>new Response('spa')}});

test('unconfigured portal and alternate hostname cannot bypass the guard through static assets',async()=>{
  for(const override of [{STAGING_PORTAL_ENABLED:'false'},{PORTAL_ORIGIN:'https://app.usesnaglist.com'},
    {BACKEND:undefined},{ASSETS:undefined}]) {
    assert.equal((await portalResponse(new Request(portalOrigin+'/'),{...env(),...override})).status,503);
  }
  assert.equal((await portalResponse(new Request('https://preview.example.com/'),env())).status,421);
});

test('same-origin API preserves binary bodies, secure independent cookies, Origin and CSRF',async()=>{
  let calls=0;
  const request=new Request(portalOrigin+'/api/v2/media/synthetic/body?revision=2',{method:'PUT',
    body:new Uint8Array([0,128,255]),headers:{Origin:portalOrigin,'Sec-Fetch-Site':'same-origin',
      Cookie:'__Host-snaglist_session=synthetic; __Host-snaglist_login=synthetic-binding',
      'X-CSRF-Token':'synthetic-csrf','Content-Type':'application/octet-stream',
      'CF-Connecting-IP':'192.0.2.6','X-Forwarded-For':'spoofed'}});
  const response=await portalResponse(request,env(async forwarded=>{
    calls++;
    assert.equal(forwarded.url,request.url);
    assert.equal(forwarded.headers.get('Origin'),portalOrigin);
    assert.equal(forwarded.headers.get('Sec-Fetch-Site'),'same-origin');
    assert.equal(forwarded.headers.get('X-CSRF-Token'),'synthetic-csrf');
    assert.equal(forwarded.headers.get('Cookie'),request.headers.get('Cookie'));
    assert.equal(forwarded.headers.get('X-Forwarded-For'),'192.0.2.6');
    assert.deepEqual(new Uint8Array(await forwarded.arrayBuffer()),new Uint8Array([0,128,255]));
    const headers=new Headers({Location:'/sign-in/verify'});
    headers.append('Set-Cookie','__Host-snaglist_session=synthetic; Path=/; Secure; HttpOnly; SameSite=Lax');
    headers.append('Set-Cookie','__Host-snaglist_login=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax');
    return new Response(null,{status:303,headers});
  }));
  assert.equal(calls,1);
  assert.equal(response.status,303);
  assert.equal(response.headers.getSetCookie().length,2);
  assert.equal(response.headers.get('Location'),'/sign-in/verify');
  assert.equal(response.headers.get('Cache-Control'),'no-store');
});

test('hostile browser Origin is preserved for server rejection, never rewritten into an authorised origin',async()=>{
  const response=await portalResponse(new Request(portalOrigin+'/api/v2/auth/email/request',{method:'POST',
    headers:{Origin:'https://attacker.example','Sec-Fetch-Site':'cross-site'}}),env(async req=>{
      assert.equal(req.headers.get('Origin'),'https://attacker.example');
      assert.equal(req.headers.get('Sec-Fetch-Site'),'cross-site');
      return new Response('forbidden',{status:403});
    }));
  assert.equal(response.status,403);
});

test('ordinary navigation returns assets; unknown APIs and wrong-host contractor routes never become SPA success',async()=>{
  for(const path of ['/sign-in/verify','/account/verify-email','/projects/synthetic','/assets/index.js']) {
    assert.equal(await (await portalResponse(new Request(portalOrigin+path),env())).text(),'spa');
  }
  for(const path of ['/api','/api/v1/projects','/m/c2_synthetic','/link/synthetic','/preview/synthetic']) {
    assert.equal((await portalResponse(new Request(portalOrigin+path),env())).status,404);
  }
  assert.equal((await portalResponse(new Request(portalOrigin+'/',{method:'POST'}),env())).status,405);
  assert.equal((await portalResponse(new Request(portalOrigin+'/api/v2/missing'),env(async()=>new Response('not found',{status:404})))).status,404);
});

test('backend network failure is explicit, redacted and never retries a write',async()=>{
  let attempts=0;
  const response=await portalResponse(new Request(portalOrigin+'/api/v2/projects',{method:'POST'}),env(async()=>{
    attempts++; throw new Error('synthetic-bearer-do-not-leak');
  }));
  assert.equal(attempts,1);
  assert.equal(response.status,503);
  assert.doesNotMatch(await response.text(),/synthetic-bearer/);
});

test('successful portal HTML supplies only the origin required by Google, including token-bearing SPA navigation',async()=>{
  const htmlEnv={...env(),ASSETS:{fetch:async()=>new Response('<!doctype html><title>Snaglist</title>',
    {headers:{'Content-Type':'text/html; charset=utf-8'}})}};
  for(const path of ['/','/sign-in/verify?token=synthetic','/account/verify-email?token=synthetic','/projects/synthetic']) {
    const response=await portalResponse(new Request(portalOrigin+path),htmlEnv);
    assert.equal(response.headers.get('Referrer-Policy'),'strict-origin');
    assert.equal(response.headers.get('Cache-Control'),'no-store');
    assert.equal(response.headers.get('X-Robots-Tag'),'noindex, nofollow');
  }
});

test('API, asset errors, script resources and Contractor paths retain no-referrer',async()=>{
  const htmlEnv={...env(async()=>new Response('private API',{headers:{'Content-Type':'text/html'}})),
    ASSETS:{fetch:async request=>new Response('asset',{status:request.url.includes('missing')?404:200,
      headers:{'Content-Type':request.url.endsWith('.js')?'text/javascript':'text/html'}})}};
  for(const path of ['/api/v2/auth/session','/health','/m/c2_synthetic','/missing','/assets/index.js']) {
    const response=await portalResponse(new Request(portalOrigin+path),htmlEnv);
    assert.equal(response.headers.get('Referrer-Policy'),'no-referrer',path);
    assert.equal(response.headers.get('Cache-Control'),'no-store',path);
  }
});
