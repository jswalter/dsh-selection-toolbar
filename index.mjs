import { spawn } from 'node:child_process';
import { access, appendFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { ConversationEngine } from './engine.mjs';

export const name = 'selection-toolbar';
export const inject = ['llm', 'agentDefaultModel', 'settings'];
const root = dirname(fileURLToPath(import.meta.url));

// Generic protocol overrides bypass the host's built-in OpenCode header wrapper.
// Scope this fallback to our own conversation and leave other plugins' calls alone.
export function registerOpenCodeHeaders(ctx, engine) {
  return ctx.on('llm-pi-ai/request-headers', (request, headers, next) => {
    const sessionId = engine.conversation?.id;
    if (sessionId && request.sessionId === sessionId) {
      let openCode = request.provider === 'opencode' || request.provider === 'opencode-go';
      if (!openCode) {
        try {
          const url = new URL(request.baseURL);
          openCode = ['https:', 'http:'].includes(url.protocol)
            && (url.hostname === 'opencode.ai' || url.hostname.endsWith('.opencode.ai'));
        } catch { /* Other providers may have no URL or an unresolved URL template. */ }
      }
      if (openCode && !headers.has('x-opencode-session')) headers.set('x-opencode-session', sessionId);
    }
    return next();
  });
}

// Use the host catalog, including external provider adapters and lazy discovery.
export async function modelCatalog(llm) {
  const providers = llm.listProviders();
  const results = await Promise.allSettled(providers.map(async provider => {
    const models = await llm.listModels(provider.id);
    return models.map(model => ({ provider: provider.id, model: model.id, name: `${provider.name ?? provider.id} · ${model.name ?? model.id}` }));
  }));
  return {
    models: results.flatMap(result => result.status === 'fulfilled' ? result.value : []),
    warnings: results.flatMap((result, index) => result.status === 'rejected' ? [providers[index].name ?? providers[index].id] : []),
  };
}

// Bound framing without readline's unbounded buffering; one private stdio peer.
export function lineReader(onLine, onError, limit = 512000) {
  let buffer = '';
  let failed = false;
  return data => {
    if (failed) return;
    buffer += data;
    if (Buffer.byteLength(buffer) > limit) { failed = true; onError(new Error('IPC message too large')); return; }
    let end;
    while ((end = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      if (line) { try { onLine(JSON.parse(line)); } catch (e) { onError(e); } }
    }
  };
}

export async function apply(ctx, config = {}) {
  if (process.platform !== 'darwin') throw new Error('AI 划词工具栏目前支持 macOS');
  const executable = config.helperPath ?? join(root, 'build', 'DSH Selection.app', 'Contents', 'MacOS', 'DSHSelection');
  await access(executable);
  const sdk = config.llmModule ? await import(pathToFileURL(config.llmModule).href) : await import('@deepseek-ai/dsh-llm');
  if (!sdk.BlockAssembler || !ctx.llm.prepareCall || !ctx.agentDefaultModel.currentSelection) throw new Error('DSH 接口不兼容，需要 0.2.2-rc.1 的模型及设置接口');
  const dataRoot = config.dataDir ?? join(process.env.DSH_HOME || join(homedir(), '.dsh'), 'selection-toolbar');
  await mkdir(join(dataRoot, 'conversations'), { recursive: true, mode: 0o700 });

  ctx.effect(() => ctx.settings.configure({ auto: false }, ctx.fiber));
  ctx.effect(() => {
    let disposed = false;
    const helper = spawn(executable, ['--bridge'], { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env } });
    function emit(value) {
      if (!disposed && !helper.stdin.destroyed && helper.stdin.writable) helper.stdin.write(`${JSON.stringify(value)}\n`);
    }
    const engine = new ConversationEngine({
      llm: ctx.llm,
      defaultRoute: () => ctx.agentDefaultModel.currentSelection(),
      BlockAssembler: sdk.BlockAssembler,
      emit,
      journal: async (id, record) => {
        if (!/^[a-f0-9-]{36}$/.test(id)) throw new Error('Invalid journal identity');
        await appendFile(join(dataRoot, 'conversations', `${id}.jsonl`), `${JSON.stringify({ time: new Date().toISOString(), ...record })}\n`, { mode: 0o600 });
      },
    });
    const disposeHeaders = registerOpenCodeHeaders(ctx, engine);
    const preferences = registerPreferences(ctx, config, emit);
    let requests = Promise.resolve();
    let generation = 0;
    async function catalog() {
      emit({ type: 'ready', ...await modelCatalog(ctx.llm), defaultRoute: ctx.agentDefaultModel.currentSelection() });
    }
    async function receive(input) {
      if (!input || typeof input !== 'object' || disposed) return;
      if (input.type === 'status') {
        const status = Object.fromEntries(['trusted', 'connected', 'paused', 'expanded', 'panelVisible'].map(key => [key, input[key] === true]));
        status.selectionStatus = String(input.selectionStatus ?? '').slice(0, 80);
        status.frontmostApp = String(input.frontmostApp ?? '').slice(0, 160);
        status.mouseButtons = Number(input.mouseButtons) || 0;
        await writeFile(join(dataRoot, 'status.json'), JSON.stringify({ ...status, pid: helper.pid, updatedAt: new Date().toISOString() }), { mode: 0o600 });
        return;
      }
      if (input.type === 'hello') {
        await preferences.initialize(input.preferences);
        return catalog();
      }
      if (input.type === 'preferences') return preferences.update(input.changes);
      if (input.type === 'models') return catalog();
      if (input.type === 'cancel') { engine.cancel(); return; }
      if (input.type === 'clear') { generation++; engine.clear(); return; }
      if (input.type === 'ask' || input.type === 'followup') {
        const queuedGeneration = generation;
        requests = requests.then(async () => {
          if (disposed || queuedGeneration !== generation) return;
          try { await engine.run(input); }
          catch (error) { emit({ type: 'error', id: input.id, message: error.message }); }
        });
        await requests;
      }
    }
    helper.stdout.setEncoding('utf8');
    helper.stdout.on('data', lineReader(value => { void receive(value).catch(() => emit({ type: 'notice', message: '无法读取模型目录，请在 DSH 检查模型设置' })); }, () => {
      engine.clear(); helper.kill(); ctx.logger?.warn('selection-toolbar: invalid helper protocol; helper stopped');
    }));
    // Never forward raw helper output or selected text into the host console.
    helper.stderr.resume();
    helper.stdin.on('error', () => engine.cancel());
    helper.on('error', error => ctx.logger?.warn(`selection-toolbar: helper start failed (${error.code ?? 'UNKNOWN'})`));
    helper.on('exit', () => { engine.clear(); if (!disposed) ctx.logger?.info('selection-toolbar: helper exited'); });
    return () => {
      disposed = true;
      disposeHeaders();
      preferences.dispose();
      engine.clear();
      helper.stdin.end();
      helper.kill('SIGTERM');
    };
  }, 'macOS selection toolbar');
}

// Both settings surfaces use the same persisted host preferences. Native writes
// only name fields actually changed, so a language edit cannot revert a model.
export function registerPreferences(ctx, config, emit) {
  let disposed = false;
  let writes = Promise.resolve();
  const sync = () => {
    const value = config.preferences.get();
    if (!disposed && value != null) emit({ type: 'preferences', preferences: value });
  };
  const stop = ctx.on('loader/volatile-update', sync);
  function enqueue(work) {
    writes = writes.catch(() => {}).then(async () => {
      if (disposed) return;
      try { await work(); sync(); }
      catch {
        sync();
        emit({ type: 'notice', message: '设置未保存，请在 DSH 插件设置中重试' });
      }
    });
    return writes;
  }
  return {
    initialize(value) {
      return enqueue(async () => {
        if (config.preferences.get() == null) {
          await ctx.settings.mutate('selection-toolbar', [{ op: 'set', path: ['preferences'], value: value ?? {} }]);
        }
      });
    },
    update(changes) {
      return enqueue(async () => {
        if (!changes || typeof changes !== 'object' || Array.isArray(changes)) throw new Error('Invalid preferences');
        const keys = Object.keys(changes);
        if (!keys.length || keys.some(key => !['paused', 'route', 'sourceLanguage', 'targetLanguage'].includes(key))) throw new Error('Invalid preference field');
        await ctx.settings.mutate('selection-toolbar', keys.map(key => ({ op: 'set', path: ['preferences', key], value: changes[key] })));
      });
    },
    dispose() { disposed = true; stop(); },
  };
}
