import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,existsSync,symlinkSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {prepareBuild} from '../scripts/prepare-build.mjs';

function fixture() {
  const root=mkdtempSync(join(tmpdir(),'snaglist-build-fixture-'));
  const repo=join(root,'repo'); mkdirSync(repo);
  const git=(...args)=>execFileSync('git',['-C',repo,...args],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
  git('init'); git('config','user.name','Synthetic build fixture'); git('config','user.email','fixture@example.test');
  mkdirSync(join(repo,'Sources/App'),{recursive:true}); mkdirSync(join(repo,'Tests/AppTests'),{recursive:true});
  for(const [path,text] of Object.entries({'Dockerfile':'FROM scratch\n','.dockerignore':'.env*\n',
    'Package.swift':'synthetic package','Package.resolved':'synthetic pins',
    'Sources/App/main.swift':'committed source','Tests/AppTests/Fixture.swift':'synthetic tests',
    '.env':'SYNTHETIC_SECRET=never-export','README.md':'not a build input'})) writeFileSync(join(repo,path),text);
  git('add','.'); git('commit','-m','Synthetic baseline');
  return {root,repo,git,commit:git('rev-parse','HEAD')};
}

test('immutable export ignores concurrent working edits, dotenv and unrelated tracked/untracked files',()=>{
  const f=fixture();
  try {
    writeFileSync(join(f.repo,'Sources/App/main.swift'),'new uncommitted source');
    writeFileSync(join(f.repo,'Sources/App/untracked.swift'),'not approved input');
    const out=join(f.root,'build'); const manifest=prepareBuild(f.repo,f.commit,out);
    assert.equal(manifest.commit,f.commit);
    assert.equal(readFileSync(join(out,'source/Sources/App/main.swift'),'utf8'),'committed source');
    for(const path of ['.env','README.md','Sources/App/untracked.swift','.git']) assert.equal(existsSync(join(out,'source',path)),false);
    const second=prepareBuild(f.repo,f.commit,join(f.root,'repeat'));
    assert.equal(second.contextSHA256,manifest.contextSHA256);
    assert.throws(()=>prepareBuild(f.repo,f.commit,out),'Existing context must never be overwritten');
  } finally { rmSync(f.root,{recursive:true,force:true}); }
});

test('source symlinks cannot import files outside the reviewed source tree',()=>{
  const f=fixture();
  try {
    symlinkSync('/synthetic/private/credential',join(f.repo,'Sources/App/secret.swift'));
    f.git('add','Sources/App/secret.swift'); f.git('commit','-m','Synthetic unsafe symlink');
    assert.throws(()=>prepareBuild(f.repo,f.git('rev-parse','HEAD'),join(f.root,'build')),/Unsafe build tree/);
    assert.equal(existsSync(join(f.root,'build')),false);
    assert.throws(()=>prepareBuild(f.repo,'HEAD',join(f.root,'build')),/hexadecimal/);
  } finally { rmSync(f.root,{recursive:true,force:true}); }
});
