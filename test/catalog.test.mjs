import test from 'node:test';
import assert from 'node:assert/strict';
import { modelCatalog } from '../index.mjs';

test('catalog includes every configured provider, waits for lazy models, and disambiguates duplicate model names', async () => {
  const calls = [];
  const result = await modelCatalog({
    listProviders: () => [{ id: 'dsh', name: 'DeepSeek' }, { id: 'external', name: 'My Gateway' }],
    listModels: async provider => {
      calls.push(provider);
      await new Promise(resolve => setTimeout(resolve, provider === 'external' ? 5 : 1));
      return [{ id: 'shared-model', name: 'Shared' }, { id: `${provider}-custom`, name: 'Custom' }];
    },
  });
  assert.deepEqual(calls, ['dsh', 'external']);
  assert.deepEqual(result.models.map(m => [m.provider, m.model, m.name]), [
    ['dsh', 'shared-model', 'DeepSeek · Shared'], ['dsh', 'dsh-custom', 'DeepSeek · Custom'],
    ['external', 'shared-model', 'My Gateway · Shared'], ['external', 'external-custom', 'My Gateway · Custom'],
  ]);
  assert.deepEqual(result.warnings, []);
});

test('one unavailable provider preserves other models and reports its display name without leaking errors', async () => {
  const result = await modelCatalog({
    listProviders: () => [{ id: 'broken', name: 'Offline Provider' }, { id: 'working', name: 'Local' }],
    listModels: async provider => {
      if (provider === 'broken') throw new Error('private transport details');
      return [{ id: 'custom', name: 'Configured model' }];
    },
  });
  assert.equal(result.models.length, 1);
  assert.equal(result.models[0].provider, 'working');
  assert.deepEqual(result.warnings, ['Offline Provider']);
  assert.ok(!JSON.stringify(result).includes('private transport'));
});

test('empty provider registries and empty configured catalogs remain empty', async () => {
  assert.deepEqual(await modelCatalog({ listProviders: () => [], listModels: () => { throw new Error('unexpected'); } }), { models: [], warnings: [] });
  assert.deepEqual(await modelCatalog({ listProviders: () => [{ id: 'empty', name: 'Empty' }], listModels: async () => [] }), { models: [], warnings: [] });
});
