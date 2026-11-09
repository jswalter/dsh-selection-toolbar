import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { settingsSchema } from '../config.mjs';
import { registerPreferences } from '../index.mjs';
const require = createRequire(process.env.DSH_TEST_RESOURCES ? join(process.env.DSH_TEST_RESOURCES, 'app.asar/dsh/package.json') : import.meta.url);
const z = require('@deepseek-ai/schemastery');
const schema = settingsSchema(z);
const defaults = { paused: false, route: null, sourceLanguage: 'auto', targetLanguage: 'zh-Hans' };
function harness(initial = null) {
  let value = initial, listener, fail = false;
  const emitted = [], writes = [];
  const ctx = {
    on(event, fn) { assert.equal(event, 'loader/volatile-update'); listener = fn; return () => { listener = null; }; },
    settings: { async mutate(ns, ops) {
      assert.equal(ns, 'selection-toolbar');
      if (fail) throw new Error('refused');
      const next = { preferences: structuredClone(value) };
      for (const op of ops) {
        if (op.path.length === 1) next.preferences = structuredClone(op.value);
        else next.preferences[op.path[1]] = structuredClone(op.value);
      }
      value = schema(next).preferences.get(); writes.push(ops); listener?.();
    } },
  };
  const bridge = registerPreferences(ctx, { preferences: { get: () => value } }, message => emitted.push(message));
  return { bridge, emitted, writes, value: () => value, change: next => { value = next; listener?.(); }, fail: next => { fail = next; } };
}
test('schema validates routes and languages, retaining existing installer config', () => {
  const resolved = schema({ helperPath: '/helper', llmModule: '/llm', dataDir: '/data', preferences: { route: null } });
  assert.deepEqual(resolved.preferences.get(), defaults);
  assert.equal(resolved.helperPath, '/helper');
  assert.equal(schema({}).preferences.get(), undefined);
  for (const preferences of [{ paused: 'yes' }, { sourceLanguage: 'bad' }, { targetLanguage: 'auto' }, { route: { provider: '', model: 'x' } }]) assert.throws(() => schema({ preferences }));
});
test('first hello migrates native preferences once and sends accepted values', async () => {
  const h = harness(); const saved = { ...defaults, route: { provider: 'external', model: 'custom' }, targetLanguage: 'ja' };
  await h.bridge.initialize(saved); await h.bridge.initialize(defaults);
  assert.deepEqual(h.value(), saved); assert.equal(h.writes.length, 1);
  assert.deepEqual(h.emitted.at(-1), { type: 'preferences', preferences: saved });
});
test('existing host settings win over stale native preferences on restart', async () => {
  const h = harness({ ...defaults, paused: true }); await h.bridge.initialize(defaults);
  assert.equal(h.writes.length, 0); assert.equal(h.emitted.at(-1).preferences.paused, true);
});
test('native field edits preserve other host changes and queued updates', async () => {
  const h = harness(defaults);
  h.change({ ...defaults, route: { provider: 'a', model: 'b' } });
  await Promise.all([h.bridge.update({ targetLanguage: 'en' }), h.bridge.update({ paused: true })]);
  assert.deepEqual(h.value(), { ...defaults, route: { provider: 'a', model: 'b' }, targetLanguage: 'en', paused: true });
});
test('refused or invalid edits restore accepted preferences, report failure and recover', async () => {
  const h = harness(defaults); h.fail(true); await h.bridge.update({ paused: true });
  assert.equal(h.value().paused, false); assert.equal(h.emitted.at(-1).type, 'notice');
  h.fail(false); await h.bridge.update({ helperPath: '/unexpected' });
  await h.bridge.update({ targetLanguage: 'auto' });
  assert.equal(h.writes.length, 0);
  await h.bridge.update({ paused: true }); assert.equal(h.value().paused, true);
});
test('dispose removes live updates and prevents queued writes', async () => {
  const h = harness(defaults); const pending = h.bridge.update({ paused: true }); h.bridge.dispose();
  await pending; h.change({ ...defaults, paused: true });
  assert.equal(h.writes.length, 0); assert.equal(h.emitted.length, 0);
});
