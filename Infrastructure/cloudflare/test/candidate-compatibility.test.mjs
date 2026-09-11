import test from 'node:test';
import assert from 'node:assert/strict';
import {legacyCandidateResponse} from '../src/candidate-compatibility.mjs';
const candidate={STAGING_DEPLOYMENT:'unified-candidate'};
const request=(path,method='POST')=>new Request('https://stage.example'+path,{method});
const affected=['/api/v1/uploads/photo?token=synthetic-do-not-echo',
 '/api/v1/magic-links/synthetic-do-not-echo/photos',
 '/api/v1/magic-links/synthetic-do-not-echo/drawings',
 '/api/v1/magic-links/synthetic-do-not-echo/report'];

test('candidate rejects historical public-media success before processing an upload or snapshot',async()=>{
  for(const path of affected) {
    const response=legacyCandidateResponse(request(path),candidate);
    assert.equal(response.status,503);
    assert.equal(response.headers.get('Cache-Control'),'no-store');
    const text=await response.text();
    assert.doesNotMatch(text,/synthetic-do-not-echo/);
    assert.equal(JSON.parse(text).identifier,'legacy_media_unavailable_in_candidate');
    assert.match(JSON.parse(text).reason,/Keep your local evidence/);
  }
});
test('recovery profile and other staging settings retain historical behaviour',()=>{
  for(const env of [{},{STAGING_DEPLOYMENT:undefined},{STAGING_PLATFORM_ENABLED:'true'},
    {STAGING_DEPLOYMENT:'unrelated'}]) {
    for(const path of affected) assert.equal(legacyCandidateResponse(request(path),env),null);
  }
});
test('canonical private media, native sign-in and unrelated legacy management are unaffected',()=>{
  for(const path of ['/api/v2/projects/synthetic/media','/api/v2/media/synthetic/content',
    '/api/v2/link-grants/synthetic/evidence','/api/v2/auth/google/verify',
    '/api/v1/auth/apple','/api/v1/auth/email','/api/v1/magic-links/synthetic/revoke',
    '/api/v1/magic-links/sync']) {
    assert.equal(legacyCandidateResponse(request(path),candidate),null);
  }
  for(const method of ['GET','HEAD','DELETE','PUT']) {
    assert.equal(legacyCandidateResponse(request('/api/v1/uploads/photo',method),candidate),null);
  }
});
test('encoded static segments, trailing separators and routing case cannot bypass the candidate guard',()=>{
  for(const path of ['/%61pi/v1/uploads/photo','/api/v1/uploads/photo/',
    '/api//v1/uploads/photo','/API/V1/UPLOADS/PHOTO',
    '/api/v1/magic-links/synthetic%2Ftoken/photos','/api/v1/magic-links/synthetic/%72eport/']) {
    assert.equal(legacyCandidateResponse(request(path),candidate).status,503);
  }
});
