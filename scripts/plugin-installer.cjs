// Run in the installed DSH Electron Node runtime (ASAR-aware).
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createRequire } = require('node:module');
const { spawnSync } = require('node:child_process');
const definitions = {
  selection: { directory: 'selection-toolbar', id: 'selection-toolbar', package: '@jswalter/dsh-selection-toolbar', legacyPackage: 'dsh-selection-toolbar', marker: 'dsh-selection-toolbar' },
};
function argumentsOf(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    if (['--dry-run', '--uninstall', '--help', '--local', '--git'].includes(key)) result[key.slice(2)] = true;
    else if (['--home', '--resources', '--workspace'].includes(key) && argv[i + 1]) result[key.slice(2)] = argv[++i];
    else throw new Error(`Unknown option: ${key}`);
  }
  return result;
}
function rewrite(text, def, config, yaml, uninstall = false) {
  const begin = `# BEGIN managed ${def.marker}`, end = `# END managed ${def.marker}`;
  const a = text.indexOf(begin), b = text.indexOf(end);
  if ((a < 0) !== (b < 0) || b < a || text.indexOf(begin, a + begin.length) >= 0 || text.indexOf(end, b + end.length) >= 0) throw new Error('Invalid managed block');
  if (a >= 0) text = text.slice(0, a) + text.slice(b + end.length).replace(/^\r?\n/, '');
  const doc = yaml.parseDocument(text);
  if (doc.errors.length || (doc.contents && !yaml.isSeq(doc.contents))) throw new Error('Invalid existing profile YAML');
  for (const row of doc.contents?.items ?? []) {
    if (row?.get?.('id') === def.id || row?.get?.('insert', true)?.items?.some(x => x?.get?.('id') === def.id)) throw new Error('Unmanaged conflicting plugin row; unchanged');
  }
  if (doc.contents?.items?.length === 0) {
    const [from, to] = doc.contents.range; text = text.slice(0, from) + text.slice(to);
  }
  if (uninstall) return text.trim() ? text : '[]\n';
  // This is a config override only. The installed bundle owns the plugin row,
  // so disabling/removing the bundle in the GUI removes its runtime component.
  return `${text.trimEnd()}\n\n${begin}\n${yaml.stringify([{ id: def.id, name: def.package, config }])}${end}\n`;
}
async function main(kind, argv = process.argv.slice(2)) {
  const def = definitions[kind]; if (!def) throw new Error('Unknown local plugin');
  const args = argumentsOf(argv);
  if (args.help) { console.log('--workspace PATH --resources PATH --home PATH --dry-run --uninstall --local --git'); return; }
  const resources = path.resolve(args.resources || '/Applications/DeepSeek Harness.app/Contents/Resources');
  const req = createRequire(path.join(resources, 'app.asar', 'dsh', 'package.json'));
  const yaml = req('yaml');
  const source = path.resolve(__dirname, '..');
  const remote = `git+https://github.com/jswalter/dsh-${def.directory}.git#main`;
  const specifier = args.local ? `link:${source}` : args.git ? remote : 'latest';
  const home = path.resolve(args.home || process.env.DSH_HOME || path.join(os.homedir(), '.dsh'));
  const profile = path.join(home, 'profiles', 'desktop');
  const patchFile = path.join(profile, 'cordis.patch.yml');
  const manifestFile = path.join(profile, 'package.json');
  if (!fs.existsSync(manifestFile)) throw new Error('Launch DSH Desktop once before installing');
  const old = fs.existsSync(patchFile) ? fs.readFileSync(patchFile, 'utf8') : '';
  let config = {};
  const parsed = yaml.parseDocument(old);
  if (parsed.errors.length) throw new Error('Existing YAML invalid');
  for (const row of parsed.contents?.items ?? []) {
    if (row?.get?.('id') === def.id) config = row.get('config')?.toJSON?.() ?? {};
    for (const child of row?.get?.('insert', true)?.items ?? []) if (child.get('id') === def.id) config = child.get('config')?.toJSON?.() ?? {};
  }
  if (kind === 'skills') {
    if (!args.uninstall) {
      const workspace = args.workspace || config.workspaceRoot;
      if (!workspace) throw new Error('Pass --workspace with the absolute path to your multi-project workspace');
      if (!path.isAbsolute(workspace)) throw new Error('--workspace must be an absolute path');
      config.workspaceRoot = fs.realpathSync(workspace);
    }
    config.filesystemModule = req.resolve('@deepseek-ai/dsh-skill-filesystem');
  } else {
    config.llmModule = req.resolve('@deepseek-ai/dsh-llm');
    config.dataDir ??= path.join(home, 'selection-toolbar');
    // Keep the authorized application location independent of the source checkout.
    config.helperPath ||= path.join(home, 'plugins', 'selection-toolbar', 'build', 'DSH Selection.app', 'Contents', 'MacOS', 'DSHSelection');
    if (!args.uninstall && !config.helperPath.endsWith(path.join('DSH Selection.app', 'Contents', 'MacOS', 'DSHSelection'))) throw new Error('Unsupported helperPath layout; expected DSH Selection.app/Contents/MacOS/DSHSelection');
  }
  const next = rewrite(old, def, config, yaml, args.uninstall);
  // Re-adding the same Git specifier can reuse the old locked commit. Explicit
  // update resolves the remote branch again while retaining its Git source.
  const previousManifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
  const updating = !!args.git && previousManifest.dependencies?.[def.package] === specifier;
  const operation = args.uninstall ? 'remove' : updating ? 'update' : 'add';
  const command = ['plugin', '--profile', 'desktop', operation, ...(args.uninstall ? [def.package] : ['--ignore-scripts', updating ? def.package : `${def.package}@${specifier}`])];
  const legacySource = previousManifest.dependencies?.[def.legacyPackage];
  if (args['dry-run']) { console.log(JSON.stringify({ package: def.package, source: specifier, command, migratingFrom: legacySource ? def.legacyPackage : undefined, config, patch: patchFile }, null, 2)); return; }
  const backup = path.join(home, 'backups', `local-bundle-${kind}-${Date.now()}`);
  fs.mkdirSync(backup, { recursive: true, mode: 0o700 });
  for (const file of ['package.json','cordis.patch.yml','pnpm-lock.yaml']) if (fs.existsSync(path.join(profile,file))) fs.copyFileSync(path.join(profile,file),path.join(backup,file));
  const cli = path.join(resources, 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh-desktop-host', 'lib', 'cli.js');
  const invoke = command => spawnSync(process.execPath, ['--expose-internals', cli, ...command], { stdio: 'inherit', env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', DSH_HOME: home } });
  if (legacySource && !args.uninstall) {
    const removed = invoke(['plugin', '--profile', 'desktop', 'remove', def.legacyPackage]);
    if (removed.status !== 0) throw new Error(`Could not migrate legacy package. Backup: ${backup}`);
  }
  const run = invoke(command);
  if (run.status !== 0 && legacySource && !args.uninstall) {
    const restored = invoke(['plugin', '--profile', 'desktop', 'add', '--ignore-scripts', `${def.legacyPackage}@${legacySource}`]);
    if (restored.status !== 0) throw new Error(`Migration and legacy package restore failed. Backup: ${backup}`);
  }
  if (run.status !== 0) throw new Error(`Official DSH installer failed; patch unchanged. Backup: ${backup}`);
  if ((fs.existsSync(patchFile) ? fs.readFileSync(patchFile,'utf8') : '') !== old) throw new Error(`Config changed during installation; review backup ${backup}`);
  if (kind === 'selection' && !args.uninstall) {
    const installedSource = args.local ? source : fs.realpathSync(path.join(profile, 'node_modules', def.package));
    await require('./helper-sync.cjs').ensureHelper(installedSource, config.helperPath);
  }
  const temporary = `${patchFile}.local-bundle.tmp`;
  fs.writeFileSync(temporary, next, { mode: 0o600 }); fs.renameSync(temporary, patchFile);
  const installed = JSON.parse(fs.readFileSync(manifestFile,'utf8'));
  const registered = installed.dsh?.profile?.bundles?.includes(def.package) ?? false;
  // Updating an intentionally disabled bundle preserves its disabled state.
  const present = Object.hasOwn(installed.dependencies ?? {}, def.package);
  if (args.uninstall ? (present || registered) : !present) throw new Error('Official package installation verification failed');
  console.log(JSON.stringify({ package: def.package, registered, source: specifier, backup }, null, 2));
}
module.exports = { main, rewrite, argumentsOf, definitions };
