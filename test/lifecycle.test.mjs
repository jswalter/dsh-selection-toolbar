import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { settingsSchema } from '../config.mjs';
import { watchEnabled } from '../index.mjs';

const resources = process.env.DSH_TEST_RESOURCES || '/Applications/DeepSeek Harness.app/Contents/Resources';
const hostModuleURL = file => pathToFileURL(path.join(resources, 'app.asar/dsh/node_modules', file)).href;
const hostModule = file => import(hostModuleURL(file));
const schemaURL = hostModuleURL('@deepseek-ai/schemastery/lib/index.mjs');
const { default: Schema } = await import(schemaURL);
const Config = settingsSchema(Schema);
const { Context } = await hostModule('@deepseek-ai/cordis/lib/index.js');
const { boot, readProfilePatches } = await hostModule('@deepseek-ai/dsh-app-boot/lib/index.js');
const require = createRequire(import.meta.url);
const yaml = require('yaml');
const { rewrite, definitions } = require('../scripts/plugin-installer.cjs');

async function until(check) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (await check()) return;
    await delay(10);
  }
  assert.fail('lifecycle did not settle');
}

test('settings schema defaults on, validates booleans and preserves installer paths', () => {
  const result = Config({ helperPath: '/helper', dataDir: '/data', llmModule: '/sdk' });
  assert.equal(result.enabled.get(), true);
  assert.equal(Config({ enabled: false }).enabled.get(), false);
  assert.equal(result.helperPath, '/helper');
  assert.equal(result.dataDir, '/data');
  assert.equal(result.llmModule, '/sdk');
  assert.throws(() => Config({ enabled: 'false' }));
});

test('rapid off/on waits for shutdown and host disposal prevents queued restarts', async () => {
  const ctx = new Context();
  let enabled = true, starts = 0, stops = 0, release;
  const cleanup = watchEnabled(ctx, () => enabled, () => {
    starts++;
    return async () => {
      stops++;
      await new Promise(resolve => { release = resolve; });
    };
  });
  await until(() => starts === 1);
  enabled = false; ctx.emit('loader/volatile-update', [['enabled']]);
  await until(() => stops === 1);
  enabled = true; ctx.emit('loader/volatile-update', [['enabled']]);
  await delay(10);
  assert.equal(starts, 1);
  const disposal = cleanup();
  release(); await disposal;
  ctx.emit('loader/volatile-update', [['enabled']]);
  await delay(10);
  assert.equal(starts, 1);
  assert.equal(stops, 1);
});

test('DSH settings persist live toggles, end child processes and requests, and survive host restart', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'dsh-selection-lifecycle-'));
  let ctx;
  t.after(async () => { await ctx?.fiber.dispose(); await rm(directory, { recursive: true, force: true }); });
  const calls = [];
  const llm = {
    listProviders: () => [],
    listModels: async () => [],
    prepareCall: async (config, signal) => {
      calls.push(signal);
      return { config, async *stream() {
        if (!signal.aborted) await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }));
      } };
    },
  };
  const pidsFile = path.join(directory, 'pids');
  const script = path.join(directory, 'helper.cjs');
  await writeFile(script, `
    require('node:fs').appendFileSync(${JSON.stringify(pidsFile)}, process.pid+'\\n');
    process.stdout.write(JSON.stringify({type:'hello'})+'\\n');
    require('node:readline').createInterface({input:process.stdin}).on('line', line => {
      if (JSON.parse(line).type === 'ready') {
        process.stdout.write(JSON.stringify({type:'ask', id:'fixture', action:'grammar', text:'Fixture text'})+'\\n');
      }
    });
    process.stdin.on('end', () => process.exit());
  `);
  const executable = path.join(directory, 'helper');
  const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
  await writeFile(executable, `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(script)}\n`, { mode: 0o700 });
  const config = {
    helperPath: executable, dataDir: path.join(directory, 'data'),
    llmModule: path.join(resources, 'app.asar/dsh/node_modules/@deepseek-ai/dsh-llm/lib/index.js'),
  };
  const fixturePlugin = path.join(directory, 'plugin.mjs');
  await writeFile(fixturePlugin, `
    import Schema from ${JSON.stringify(schemaURL)};
    import { settingsSchema } from ${JSON.stringify(new URL('../config.mjs', import.meta.url).href)};
    export { name, inject, apply } from ${JSON.stringify(new URL('../index.mjs', import.meta.url).href)};
    export const Config = settingsSchema(Schema);
  `);
  const definition = { ...definitions.selection, package: pathToFileURL(fixturePlugin).href };
  const installed = name => path.join(resources, 'app.asar/dsh/node_modules/@deepseek-ai', name, 'lib/index.js');
  const bundle = path.join(directory, 'node_modules', 'fixture-bundle');
  const root = path.join(directory, 'cordis.yml');
  const patchPath = path.join(directory, 'cordis.patch.yml');
  await mkdir(bundle, { recursive: true });
  await writeFile(path.join(directory, 'package.json'), JSON.stringify({ dsh: { profile: { bundles: ['fixture-bundle'] } } }));
  await writeFile(path.join(bundle, 'package.json'), JSON.stringify({ name: 'fixture-bundle', dsh: { bundle: { patch: './cordis.patch.yml' } } }));
  await writeFile(path.join(bundle, 'cordis.patch.yml'), JSON.stringify([{ insert: [
    { id: 'config-editor', name: installed('dsh-config-editor') },
    { id: 'settings', name: installed('dsh-settings') },
    { id: 'selection-toolbar', name: definition.package, config },
  ] }]));
  await writeFile(root, '[]\n');
  await writeFile(patchPath, rewrite('[]\n', definition, { ...config, enabled: false }, yaml));
  const profile = {
    name: 'fixture', dir: directory, patchPath, cwd: directory,
    home: path.join(directory, 'home'), overlays: [], startedBundles: [],
    installAnchor: path.join(resources, 'app.asar/dsh/package.json'),
  };
  const startHost = () => boot('dsh', root, readProfilePatches('dsh', profile), context => {
    context.provide('profileContext', profile);
    context.provide('llm', llm);
    context.provide('agentDefaultModel', { currentSelection: () => ({ provider: 'fixture', model: 'fixture' }) });
  });
  ctx = await startHost();
  const form = () => ctx.settings.describe().find(row => row.ns === 'selection-toolbar');
  const toggle = value => ctx.settings.mutate('selection-toolbar', [{ op: 'set', path: ['enabled'], value }], form().revision);
  const pids = async () => (await readFile(pidsFile, 'utf8')).trim().split('\n').map(Number);
  const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
  const entry = [...ctx.loader.entries()].find(row => row.options.id === 'selection-toolbar');
  assert.equal(entry.fiber.state, 2, 'plugin must serve settings while off');
  assert.equal(form().value.enabled, false);
  assert.equal(form().autoGenerate, false);
  assert.deepEqual(Object.keys(form().value), ['enabled'], 'installer paths stay outside the settings form');
  const fiber = entry.fiber;
  await delay(20);
  assert.equal(calls.length, 0);
  await toggle(true);
  await until(() => calls.length === 1);
  const defaultPreferences = { paused: false, route: null, sourceLanguage: 'auto', targetLanguage: 'zh-Hans' };
  await until(() => form().value.preferences != null);
  assert.deepEqual({ route: null, ...form().value.preferences }, defaultPreferences, 'the first helper hello initializes preferences');
  assert.deepEqual(Object.keys(form().value).sort(), ['enabled', 'preferences']);
  assert.equal(entry.fiber, fiber, 'volatile settings must not remount the settings owner');
  await toggle(false);
  await until(() => calls[0].aborted);
  await until(async () => !(await pids()).some(alive));
  assert.equal(form().value.enabled, false, 'the off switch remains served');
  const persisted = await readFile(patchPath, 'utf8');
  assert.match(persisted, /enabled: false/);
  const savedConfig = yaml.parse(persisted).find(row => row.id === 'selection-toolbar').config;
  for (const [key, value] of Object.entries(config)) {
    assert.equal(savedConfig[key], value, `settings writes preserve ${key}`);
  }
  assert.equal(savedConfig.enabled, false);
  assert.ok(savedConfig.preferences, 'turning the helper off preserves the persisted preferences object');
  assert.deepEqual({ route: null, ...Config(savedConfig).preferences.get() }, defaultPreferences);
  assert.doesNotThrow(() => rewrite(persisted, definition, savedConfig, yaml), 'settings writes retain the installer-managed block');
  await toggle(true);
  await until(() => calls.length === 2);
  assert.equal(calls[1].aborted, false);
  assert.equal((await pids()).length, 2);
  await ctx.fiber.dispose();
  await until(() => calls[1].aborted);
  await until(async () => !(await pids()).some(alive));
  ctx = await startHost();
  await until(() => calls.length === 3);
  assert.equal(form().value.enabled, true, 'the enabled preference survives host restart');
  await toggle(false);
  await until(async () => !(await pids()).some(alive));
  await ctx.fiber.dispose();
  ctx = await startHost();
  assert.equal(form().value.enabled, false, 'the disabled preference survives host restart');
  await delay(30);
  assert.equal(calls.length, 3, 'restarting a disabled plugin does not spawn a helper');
});
