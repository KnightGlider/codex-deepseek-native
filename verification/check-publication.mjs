#!/usr/bin/env node
// Read-only checks of the files staged for publication; never prints secret values.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = execFileSync('git', ['ls-files', '--cached', '-z'], {cwd:root, encoding:'utf8'}).split('\0').filter(Boolean);
if (!files.length) throw new Error('No staged/tracked files: stage the curated kit first.');
const failures=[];
const tracked=new Set(files);
const actualHome=(process.env.USERPROFILE || os.homedir()).replaceAll('\\','/').toLowerCase();
const forbiddenName=/(?:^|\/)(?:auth\.json|config\.toml|\.env(?:\..*)?|.*\.secret)$/i;
const forbiddenArtifact=/\.(?:exe|dll|zip|7z|zst|log|jsonl|tar|gz)$/i;
const keyPatterns=[/\bsk-[A-Za-z0-9_-]{20,}/g,/\bgh[pousr]_[A-Za-z0-9]{20,}/g,/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g];
for(const file of files){
 if(forbiddenName.test(file)||forbiddenArtifact.test(file)) failures.push({file,reason:'credential/state/generated artifact filename'});
 const staged=execFileSync('git',['show',`:${file}`],{cwd:root,maxBuffer:6*1024*1024});
 if(staged.length>2*1024*1024){failures.push({file,reason:'unexpectedly large Git file'});continue;}
 if(staged.includes(0)){failures.push({file,reason:'binary data in source repository'});continue;}
 const text=staged.toString('utf8');
 if(text.replaceAll('\\','/').replace(/\/+/g,'/').toLowerCase().includes(actualHome)) failures.push({file,reason:'current machine home path'});
 for(const pattern of keyPatterns){pattern.lastIndex=0;if(pattern.test(text))failures.push({file,reason:'possible credential/private key; value withheld'});}
 if(file.endsWith('.md')){
  const links=[...text.matchAll(/\]\((<[^>]+>|[^)\s]+)(?:\s+[^)]*)?\)/g)];
  for(const match of links){let target=match[1].replace(/^<|>$/g,'').split('#')[0];if(!target||/^[a-z][a-z0-9+.-]*:/i.test(target))continue;
   try{target=decodeURIComponent(target);}catch{failures.push({file,reason:'invalid link encoding'});continue;}
   const resolved=path.resolve(path.dirname(path.join(root,file)),target);
   if(!fs.existsSync(resolved)) failures.push({file,reason:`missing local documentation link: ${target}`});
   else {
    const relative=path.relative(root,resolved).split(path.sep).join('/');
    const included=fs.statSync(resolved).isDirectory()
      ? files.some(name=>name.startsWith(relative+'/')) : tracked.has(relative);
    if(relative.startsWith('../') || !included) failures.push({file,reason:`documentation link not included in Git: ${target}`});
   }
  }
 }
}
if(failures.length){for(const failure of failures)console.error(JSON.stringify(failure));process.exitCode=1;}
else console.log(`Publication checks passed for ${files.length} staged files. This is a targeted check, not a guarantee that arbitrary data is safe to publish.`);
