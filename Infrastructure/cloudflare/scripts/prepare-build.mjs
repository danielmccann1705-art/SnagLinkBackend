import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdirSync, writeFileSync} from 'node:fs';
import {isAbsolute, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const allowed = path => ['Dockerfile','.dockerignore','Package.swift','Package.resolved'].includes(path) ||
  path.startsWith('Sources/') || path.startsWith('Tests/');

// Export object bytes from one commit, never the changing working directory.
// The only writes are to a new caller-selected build directory.
export function prepareBuild(repository, revision, outputDirectory) {
  if (!isAbsolute(repository) || !isAbsolute(outputDirectory)) throw new Error('Absolute paths required');
  if (!/^[a-f0-9]{7,40}$/.test(revision)) throw new Error('Use a reviewed hexadecimal commit reference');
  const commit=execFileSync('git',['-C',repository,'rev-parse','--verify',`${revision}^{commit}`],{encoding:'utf8'}).trim();
  const tracked=execFileSync('git',['-C',repository,'ls-tree','-rz',commit],{maxBuffer:64*1024*1024}).toString().split('\0').filter(Boolean);
  const entries=tracked.map(row=>{
    const split=row.indexOf('\t'); const [mode,type,object]=row.slice(0,split).split(' ');
    return {mode,type,object,path:row.slice(split+1)};
  }).filter(e=>allowed(e.path));
  for(const entry of entries) {
    if(entry.type!=='blob' || !['100644','100755'].includes(entry.mode) ||
      entry.path.split('/').some(p=>!p || p==='.' || p==='..')) throw new Error('Unsafe build tree entry');
  }
  for(const required of ['Dockerfile','.dockerignore','Package.swift','Package.resolved']) {
    if(!entries.some(e=>e.path===required)) throw new Error(`Missing ${required}`);
  }
  mkdirSync(outputDirectory,{recursive:false});
  const source=join(outputDirectory,'source'); mkdirSync(source);
  const manifest=[];
  for(const entry of entries.sort((a,b)=>a.path.localeCompare(b.path,'en'))) {
    const bytes=execFileSync('git',['-C',repository,'cat-file','blob',entry.object],{maxBuffer:64*1024*1024});
    const parent=entry.path.slice(0,entry.path.lastIndexOf('/'));
    if(entry.path.includes('/')) mkdirSync(join(source,parent),{recursive:true});
    writeFileSync(join(source,entry.path),bytes,{flag:'wx',mode:entry.mode==='100755'?0o755:0o644});
    manifest.push({path:entry.path,mode:entry.mode,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')});
  }
  const result={format:1,commit,platform:'linux/amd64',files:manifest,
    contextSHA256:createHash('sha256').update(JSON.stringify(manifest)).digest('hex'),
    note:'Committed build inputs only. No credentials, uncommitted source, deployment or test execution included.'};
  writeFileSync(join(outputDirectory,'SOURCE-MANIFEST.json'),JSON.stringify(result,null,2)+'\n',{flag:'wx'});
  return result;
}

if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [repository,revision,outputDirectory]=process.argv.slice(2);
  const manifest=prepareBuild(repository,revision,outputDirectory);
  console.log(JSON.stringify({commit:manifest.commit,contextSHA256:manifest.contextSHA256,files:manifest.files.length}));
}
