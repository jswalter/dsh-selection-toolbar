import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

// Exercise the shipped lazy bundle and its settings transport without a browser
// or writes to the user's profile. Hooks retain state across explicit renders.
async function harness() {
  let declaration, contribution, Component, cursor = 0;
  const states = [], writes = [];
  let snapshot = { status: 'ready', writable: true, value: { enabled: true } };
  let save = async (key, value) => { snapshot = { ...snapshot, value: { [key]: value } }; return true; };
  const React = {
    createElement: (type, props, ...children) => ({ type, props: props ?? {}, children }),
    useCallback: fn => fn,
    useSyncExternalStore: (_subscribe, get) => get(),
    useState(initial) {
      const index = cursor++;
      if (!(index in states)) states[index] = initial;
      return [states[index], value => { states[index] = value; }];
    },
  };
  const scope = {
    getSnapshot: () => snapshot, subscribe: () => () => {},
    set: async (...args) => { writes.push(args); return save(...args); },
  };
  vm.runInNewContext(await readFile(new URL('../client.js', import.meta.url), 'utf8'), {
    window: { __ModuleLoader__: { load: value => { declaration = value; } } },
  });
  const manifest = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(declaration.id, manifest.name);
  assert.equal(manifest.exports['./client'], './client.js');
  const plugin = declaration.factory(name => {
    if (name === 'react') return React;
    if (name === '@deepseek-ai/dsh-client-ui-primitives') return { Switch: 'Switch' };
    assert.fail(`unsupported client external: ${name}`);
  });
  const dictionaries = {};
  const ctx = {
    effect: run => run(),
    locale: {
      register: (ns, values) => { dictionaries[ns] = values.zh; return () => {}; },
      bind: ns => key => dictionaries[ns][key],
    },
    configForms: {
      get: id => { assert.equal(id, 'selection-toolbar'); return scope; },
      whileServed: (ids, register) => { assert.equal(ids[0], 'selection-toolbar'); return register(); },
    },
    slots: {
      inject: (name, register) => { assert.equal(name, 'settings.section'); return register(); },
      register: (options, component) => { contribution = options; Component = component; return () => {}; },
    },
  };
  plugin.apply(ctx);
  const render = () => {
    cursor = 0;
    return Component({ ...contribution.inject(), t: ctx.locale.bind(contribution.locale) });
  };
  const find = (node, predicate) => predicate(node) ? node : node.children?.map(child => typeof child === 'object' && child ? find(child, predicate) : undefined).find(Boolean);
  return {
    writes, render, find,
    control: () => find(render(), node => node.type === 'Switch').props,
    state: value => { snapshot = { ...snapshot, ...value }; },
    saving: fn => { save = fn; },
  };
}

test('DSH settings switch writes the enabled preference and follows accepted values', async () => {
  const h = await harness();
  assert.equal(h.control().checked, true);
  await h.control().onChange(false);
  assert.deepEqual(h.writes, [['enabled', false]]);
  assert.equal(h.control().checked, false);
  await h.control().onChange(true);
  assert.equal(h.control().checked, true);
});

test('settings failures retain accepted state; pending, read-only and unavailable forms block writes', async () => {
  const h = await harness();
  let finish;
  h.saving(() => new Promise(resolve => { finish = resolve; }));
  const pending = h.control().onChange(false);
  assert.equal(h.control().disabled, true);
  await h.control().onChange(false);
  assert.equal(h.writes.length, 1);
  finish(false); await pending;
  assert.equal(h.control().checked, true);
  assert.ok(h.find(h.render(), node => node.props.role === 'alert'));
  h.saving(async () => { throw new Error('offline'); });
  await h.control().onChange(false);
  assert.equal(h.control().checked, true);
  const count = h.writes.length;
  for (const state of [{ writable: false }, { writable: true, status: 'unavailable' }]) {
    h.state(state);
    assert.equal(h.control().disabled, true);
    await h.control().onChange(false);
    assert.equal(h.writes.length, count);
  }
});
