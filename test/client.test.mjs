import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

// Run the shipped bundle with stable hooks and a revisioned settings fixture.
async function harness() {
  let declaration, Component, cursor = 0;
  const states = [], writes = [], slots = [];
  let snapshot = { status: 'ready', writable: true, revision: 'one', value: { enabled: true, preferences: { paused: false, route: null, sourceLanguage: 'auto', targetLanguage: 'zh-Hans' } } };
  let save = async ops => {
    const value = { ...snapshot.value };
    for (const op of ops) value[op.path[0]] = op.value;
    snapshot = { ...snapshot, value, revision: 'two' }; return true;
  };
  const React = {
    createElement: (type, props, ...children) => ({ type, props: props ?? {}, children: children.flat(Infinity) }),
    useSyncExternalStore: (_subscribe, get) => get(),
    useEffect: () => {},
    useRef: value => ({ current: value }),
    useState(initial) {
      const index = cursor++;
      if (!(index in states)) states[index] = initial;
      return [states[index], value => { states[index] = value; }];
    },
  };
  const form = { getSnapshot: () => snapshot, subscribe: () => () => {}, mutate: async (...args) => { writes.push(args); return save(...args); } };
  vm.runInNewContext(await readFile(new URL('../client.js', import.meta.url), 'utf8'), {
    window: { __ModuleLoader__: { load: value => { declaration = value; } } },
  });
  const manifest = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(declaration.id, manifest.name);
  assert.equal(manifest.exports['./client'], './client.js');
  const plugin = declaration.factory(name => { assert.equal(name, 'react'); return React; });
  plugin.apply({
    effect: run => run(),
    remote: { session: { modelCatalog: async () => ({ ok: true, value: { groups: [{ id: 'provider', name: 'Provider', models: [{ id: 'model', name: 'Model' }] }] } }) } },
    configForms: { get: id => { assert.equal(id, 'selection-toolbar'); return form; } },
    slots: {
      inject: (name, register) => { assert.ok(['plugins.bundle.config', 'plugins.row.config'].includes(name)); return register(); },
      register: (options, component) => { slots.push(options); Component = component; return () => {}; },
    },
  });
  assert.deepEqual(slots.map(slot => slot.key), ['@jswalter/dsh-selection-toolbar', '@jswalter/dsh-selection-toolbar#selection-toolbar']);
  const render = () => { cursor = 0; return Component(); };
  const find = (node, predicate) => predicate(node) ? node : node.children?.map(child => typeof child === 'object' && child ? find(child, predicate) : undefined).find(Boolean);
  return {
    writes, render, find,
    control: () => find(render(), node => node.type === 'input').props,
    submit: () => render().props.onSubmit({ preventDefault() {} }),
    state: value => { snapshot = { ...snapshot, ...value }; },
    saving: fn => { save = fn; },
  };
}

test('plugin detail stages edits, then atomically saves enabled and preferences with the read revision', async () => {
  const h = await harness();
  h.control().onChange({ target: { checked: false } });
  assert.equal(h.writes.length, 0);
  assert.equal(h.control().checked, false);
  await h.submit();
  assert.equal(h.writes[0][1], 'one');
  assert.equal(h.writes[0][0][0].value, false);
  assert.equal(h.writes[0][0][1].value.targetLanguage, 'zh-Hans');
  assert.equal(h.control().checked, false);
});

test('failed or conflicting saves retain drafts and prevent writes while pending or read-only', async () => {
  const h = await harness(); let finish;
  h.control().onChange({ target: { checked: false } });
  h.saving(() => new Promise(resolve => { finish = resolve; }));
  const pending = h.submit();
  assert.equal(h.control().disabled, true); await h.submit(); assert.equal(h.writes.length, 1);
  finish(false); await pending;
  assert.equal(h.control().checked, false);
  assert.ok(h.find(h.render(), node => node.props.role === 'status' && node.children.some(child => typeof child === 'string' && child.includes('保存未成功'))));
  h.saving(async () => { throw new Error('offline'); }); await h.submit();
  assert.equal(h.control().checked, false);
  const count = h.writes.length;
  for (const state of [{ writable: false }, { writable: true, status: 'unavailable' }]) {
    h.state(state); assert.equal(h.control().disabled, true); await h.submit(); assert.equal(h.writes.length, count);
  }
});

test('refresh loads the host catalog and selected route saves provider and model together', async () => {
  const h = await harness();
  await h.find(h.render(), node => node.type === 'button' && node.children.includes('刷新模型列表')).props.onClick();
  const modelSelect = h.find(h.render(), node => node.type === 'select');
  assert.ok(modelSelect.children.some(option => option?.children.includes('Provider · Model')));
  modelSelect.props.onChange({ target: { value: JSON.stringify(['provider', 'model']) } });
  await h.submit();
  assert.equal(h.writes[0][0][1].value.route.provider, 'provider');
  assert.equal(h.writes[0][0][1].value.route.model, 'model');
});
