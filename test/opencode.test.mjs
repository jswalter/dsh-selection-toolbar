import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { registerOpenCodeHeaders } from '../index.mjs';

const resources = process.env.DSH_TEST_RESOURCES || '/Applications/DeepSeek Harness.app/Contents/Resources';
const hostModule = file => import(pathToFileURL(path.join(resources, 'app.asar/dsh/node_modules', file)).href);
const { Context } = await hostModule('@deepseek-ai/cordis/lib/index.js');
const { PiAiAdapter } = await hostModule('@deepseek-ai/dsh-llm-pi-ai/lib/index.js');
const { opencodeGoProvider } = await hostModule('@earendil-works/pi-ai/dist/providers/opencode-go.js');
const { opencodeProvider } = await hostModule('@earendil-works/pi-ai/dist/providers/opencode.js');
const { createProvider } = await hostModule('@earendil-works/pi-ai/dist/models.js');
const { openAICompletionsApi } = await hostModule('@earendil-works/pi-ai/dist/api/openai-completions.lazy.js');

function headerHarness() {
  const ctx = new Context();
  const engine = { conversation: { id: 'selection-conversation-1' } };
  const dispose = registerOpenCodeHeaders(ctx, engine);
  const prepare = (request, headers = new Headers()) => ctx.waterfall('llm-pi-ai/request-headers', request, headers, () => headers);
  return { ctx, engine, dispose, prepare };
}

test('OpenCode routing headers use exact provider IDs or parsed endpoint hostnames', () => {
  const h = headerHarness();
  for (const request of [
    { provider: 'opencode' }, { provider: 'opencode-go' },
    { provider: 'custom', baseURL: 'https://opencode.ai/zen/v1' },
    { provider: 'custom', baseURL: 'https://OPENCODE.AI/zen/go/v1' },
    { provider: 'custom', baseURL: 'https://api.opencode.ai/v1' },
    { provider: 'opencode-go', baseURL: 'https://proxy.example.test/v1' },
  ]) {
    const headers = h.prepare({ ...request, sessionId: h.engine.conversation.id });
    assert.equal(headers.get('x-opencode-session'), h.engine.conversation.id, JSON.stringify(request));
  }
  for (const baseURL of [
    undefined, '', 'not a URL', 'https://api.deepseek.com/v1',
    'https://opencode.ai.example.test/v1', 'https://notopencode.ai/v1',
    'https://example.test/opencode.ai', 'https://opencode.ai@example.test/v1',
    'file://opencode.ai/v1',
  ]) {
    const headers = h.prepare({ provider: 'custom-opencode-name', baseURL, sessionId: h.engine.conversation.id });
    assert.equal(headers.has('x-opencode-session'), false, String(baseURL));
  }
  h.dispose();
});

test('header fallback preserves configured headers, ignores other conversations, and unregisters', () => {
  const h = headerHarness();
  const request = { provider: 'opencode-go', sessionId: h.engine.conversation.id };
  const configured = new Headers({ 'X-OpenCode-Session': 'configured-session', 'X-Custom': 'retained' });
  assert.deepEqual([...h.prepare(request, configured)], [...configured]);
  assert.equal(configured.get('x-opencode-session'), 'configured-session');
  for (const sessionId of [undefined, '', 'main-chat-session']) {
    assert.equal(h.prepare({ ...request, sessionId }).has('x-opencode-session'), false);
  }
  h.engine.conversation = null;
  assert.equal(h.prepare(request).has('x-opencode-session'), false);
  h.engine.conversation = { id: request.sessionId };
  assert.equal(h.prepare(request).get('x-opencode-session'), request.sessionId);
  h.dispose();
  assert.equal(h.prepare(request).has('x-opencode-session'), false);
});

// Exercise the installed adapter and HTTP serializer with synthetic credentials
// and intercepted fetch: no request reaches a provider or reads account secrets.
test('installed DSH adapter sends OpenCode session headers on built-in and generic protocol routes', async t => {
  const captured = [];
  t.mock.method(globalThis, 'fetch', async (input, init) => {
    const request = new Request(input, init);
    const body = await request.json();
    captured.push({ url: request.url, headers: request.headers, body });
    const chunks = [
      { id: 'fixture', object: 'chat.completion.chunk', model: body.model, choices: [{ index: 0, delta: { role: 'assistant', content: 'Fixture answer' }, finish_reason: null }] },
      { id: 'fixture', object: 'chat.completion.chunk', model: body.model, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] },
    ];
    return new Response(chunks.map(chunk => `data: ${JSON.stringify(chunk)}\n\n`).join('') + 'data: [DONE]\n\n', {
      headers: { 'content-type': 'text/event-stream' },
    });
  });
  for (const fixture of [
    { base: opencodeGoProvider(), builtin: true },
    { base: opencodeProvider(), builtin: true },
    { base: opencodeGoProvider(), id: 'opencode-go', baseURL: 'https://opencode.ai/zen/go/v1' },
    { base: opencodeGoProvider(), id: 'custom-gateway', baseURL: 'https://opencode.ai/zen/go/v1' },
    { base: opencodeGoProvider(), id: 'other-provider', baseURL: 'https://other.example.test/v1' },
  ]) {
    const h = headerHarness();
    const id = fixture.id ?? fixture.base.id;
    const model = { ...fixture.base.getModels().find(model => model.api === 'openai-completions'), provider: id };
    assert.ok(model.id, 'installed catalog needs an OpenAI-compatible model');
    if (fixture.baseURL) model.baseUrl = fixture.baseURL;
    const piProvider = fixture.builtin ? { ...fixture.base, getModels: () => [model] } : createProvider({
      id, name: id, models: [model], auth: fixture.base.auth, api: openAICompletionsApi(),
    });
    const profiles = new Map([[id, {
      piProvider, modelErrors: new Map(), configuredMaxTokens: new Map(), streamIdleTimeoutMs: 1000,
      headers: { 'x-custom': 'retained' },
    }]]);
    const adapter = new PiAiAdapter({ profiles: () => profiles, resolveApiKey: async () => 'fixture-key', prepareHeaders: h.prepare });
    const call = await adapter.prepareCall(id, model.id);
    const chunks = [];
    for await (const chunk of call.stream({
      provider: id, model: model.id, sessionId: h.engine.conversation.id,
      messages: [{ id: 'fixture-user', role: 'user', content: [{ type: 'text', text: 'Fixture input' }], source: { kind: 'selection-toolbar' } }],
      tools: [], maxTokens: 32,
    })) chunks.push(chunk);
    assert.equal(chunks.at(-1)?.reason?.kind, 'stop', JSON.stringify(chunks));
    const sent = captured.at(-1);
    assert.equal(sent.headers.get('x-opencode-session'), id === 'other-provider' ? null : h.engine.conversation.id, id);
    assert.equal(sent.headers.get('x-custom'), 'retained');
    assert.ok(sent.headers.get('user-agent'), 'host attribution is retained');
    assert.equal(Object.hasOwn(sent.body, 'sessionId'), false, 'session metadata is not a model body parameter');
    h.dispose();
  }
  assert.equal(captured.length, 5);
});
