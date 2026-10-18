import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const run = promisify(execFile);
import {readFile,readdir} from 'node:fs/promises';
import assert from 'node:assert/strict';
import path from 'node:path';

const tracked=(await run('git',['ls-files','--cached','--others','--exclude-standard'],{encoding:'utf8'})).stdout.trim().split('\n').filter(Boolean);
const forbidden=tracked.filter(file=>/^(\.env\.(?!example)|Config\/Local\.xcconfig|HouseholdOS\/ServiceConfiguration\.plist)/.test(file));
assert.deepEqual(forbidden,[],'Private local configuration must stay out of source control');
for(const file of tracked) {
  const text=await readFile(file,'utf8');
  assert.equal(/(?:sk_live_|sk_test_|sb_secret_)[a-zA-Z0-9]{12,}/.test(text),false,`Secret-like value in ${file}`);
  assert.equal(/PLAID_SECRET\s*=\s*[a-f0-9]{20,}/i.test(text),false,`Plaid secret in ${file}`);
  if(file.endsWith('.json')) JSON.parse(text);
}
const project=await readFile('HouseholdOS.xcodeproj/project.pbxproj','utf8');
assert.match(project,/version = 6\.5\.4/);
assert.match(project,/IPHONEOS_DEPLOYMENT_TARGET = 18\.0/);
assert.equal(project.includes('SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx'),false);
const auth=await readFile('supabase/config.toml','utf8');
assert.match(auth,/enable_confirmations = true/);
assert.match(auth,/verify_jwt = false/); // Handler verifies Auth and signed webhooks itself.
const files=await readdir('supabase/migrations');
assert.ok(files.length>=5);
await run('git',['diff','--check']);
console.log(`Repository checks passed (${tracked.length} source files; local secrets excluded).`);
