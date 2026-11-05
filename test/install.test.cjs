'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const {createRequire} = require('node:module');
const {rewrite,argumentsOf,definitions} = require('../scripts/plugin-installer.cjs');
const resources=process.env.DSH_TEST_RESOURCES || '/Applications/DeepSeek Harness.app/Contents/Resources';
const yaml=createRequire(path.join(resources,'app.asar','dsh','package.json'))('yaml');
for(const def of Object.values(definitions)) {
 test(`${def.id}: migrate direct row to idempotent config override`,()=>{
  const unrelated='- id: other\n  config:\n    expression: !!js process.env.VALUE\n';
  const old=`${unrelated}# BEGIN managed ${def.marker}\n- insert:\n    - id: ${def.id}\n      name: /legacy/index.mjs\n# END managed ${def.marker}\n`;
  const config={workspaceRoot:'/example',dataDir:'/data'};
  const next=rewrite(old,def,config,yaml);
  assert.ok(next.startsWith(unrelated));
  const rows=yaml.parse(next);assert.equal(rows.length,2);assert.equal(rows[1].id,def.id);assert.equal(rows[1].name,def.package);assert.deepEqual(rows[1].config,config);assert.equal(rows[1].insert,undefined);
  assert.equal(rewrite(next,def,config,yaml),next);
  assert.equal(rewrite(next,def,{},yaml,true).trim(),unrelated.trim());
 });
 test(`${def.id}: empty document and malformed/conflicting blocks`,()=>{
  assert.equal(yaml.parse(rewrite('# comment\n[]\n',def,{},yaml)).length,1);
  for(const s of ['- broken: [', 'key: value',`- id: ${def.id}\n`, `# END managed ${def.marker}\n`, `# BEGIN managed ${def.marker}\n`]) assert.throws(()=>rewrite(s,def,{},yaml));
 });
}
test('arguments remain compatible with existing launchers',()=>{
 assert.deepEqual(argumentsOf(['--workspace','/repo','--dry-run']),{workspace:'/repo','dry-run':true});
 assert.throws(()=>argumentsOf(['--unknown']));
});
