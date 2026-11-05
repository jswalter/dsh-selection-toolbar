// Run in the installed DSH Electron Node runtime (ASAR-aware).
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createRequire } = require('node:module');
const { spawnSync } = require('node:child_process');
const definitions = {
  selection: { directory: 'selection-toolbar', id: 'selection-toolbar', package: 'dsh-selection-toolbar', marker: 'dsh-selection-toolbar' },
};
function argumentsOf(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    if (['--dry-run', '--uninstall', '--help', '--local'].includes(key)) result[key.slice(2)] = true;
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
  if (args.help) { console.log('--workspace PATH --resources PATH --home PATH --dry-run --uninstall --local'); return; }
  const resources = path.resolve(args.resources || '/Applications/DeepSeek Harness.app/Contents/Resources');
  const req = createRequire(path.join(resources, 'app.asar', 'dsh', 'package.json'));
  const yaml = req('yaml');
  const source = path.resolve(__dirname, '..');
  const remote = `git+https://github.com/jswalter/dsh-${def.directory}.git#main`;
  const specifier = args.local ? `link:${source}` : remote;
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
  const command = ['plugin', '--profile', 'desktop', args.uninstall ? 'remove' : 'add', ...(args.uninstall ? [def.package] : ['--ignore-scripts', `${def.package}@${specifier}`])];
  if (args['dry-run']) { console.log(JSON.stringify({ package: def.package, source: specifier, command, config, patch: patchFile }, null, 2)); return; }
  const backup = path.join(home, 'backups', `local-bundle-${kind}-${Date.now()}`);
  fs.mkdirSync(backup, { recursive: true, mode: 0o700 });
  for (const file of ['package.json','cordis.patch.yml','pnpm-lock.yaml']) if (fs.existsSync(path.join(profile,file))) fs.copyFileSync(path.join(profile,file),path.join(backup,file));
  const cli = path.join(resources, 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh-desktop-host', 'lib', 'cli.js');
  const run = spawnSync(process.execPath, ['--expose-internals', cli, ...command], { stdio: 'inherit', env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', DSH_HOME: home } });
  if (run.status !== 0) throw new Error(`Official DSH installer failed; patch unchanged. Backup: ${backup}`);
  if ((fs.existsSync(patchFile) ? fs.readFileSync(patchFile,'utf8') : '') !== old) throw new Error(`Config changed during installation; review backup ${backup}`);
  if (kind === 'selection' && !args.uninstall) {
    const installedSource = args.local ? source : fs.realpathSync(path.join(profile, 'node_modules', def.package));
    const helperApp = path.resolve(config.helperPath, '../../..');
    const helperPlist = path.join(helperApp, 'Contents', 'Info.plist');
    let bundleId = 'local.dsh.selection-toolbar';
    if (fs.existsSync(helperPlist)) {
      const readId = spawnSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', helperPlist], { encoding: 'utf8' });
      if (readId.status !== 0 || !/^[A-Za-z0-9][A-Za-z0-9.-]+$/.test(readId.stdout.trim())) throw new Error('Could not read the existing helper identity; application unchanged');
      bundleId = readId.stdout.trim();
    }
    const buildOutput = path.join(backup, 'build');
    const build = spawnSync('sh', [path.join(installedSource, 'scripts', 'build.sh'), buildOutput], {
      stdio: 'inherit', env: { ...process.env, DSH_SELECTION_BUNDLE_ID: bundleId, DSH_SELECTION_TMP: process.env.DSH_SELECTION_TMP || path.join(buildOutput, '.cache') },
    });
    if (build.status !== 0) throw new Error(`Native build failed; existing helper and patch unchanged. Backup: ${backup}`);
    if (fs.existsSync(helperApp)) {
      const saved = spawnSync('/usr/bin/ditto', [helperApp, path.join(backup, 'DSH Selection.app')], { stdio: 'inherit' });
      if (saved.status !== 0) throw new Error(`Could not back up helper: ${backup}`);
    }
    fs.mkdirSync(path.dirname(helperApp), { recursive: true });
    const copy = spawnSync('/usr/bin/ditto', [path.join(buildOutput, 'DSH Selection.app'), helperApp], { stdio: 'inherit' });
    if (copy.status !== 0) throw new Error(`Helper copy failed. Restore the application from ${backup}`);
    fs.accessSync(config.helperPath, fs.constants.X_OK);
    fs.rmSync(buildOutput, { recursive: true, force: true });
  }
  const temporary = `${patchFile}.local-bundle.tmp`;
  fs.writeFileSync(temporary, next, { mode: 0o600 }); fs.renameSync(temporary, patchFile);
  const installed = JSON.parse(fs.readFileSync(manifestFile,'utf8'));
  const registered = installed.dsh?.profile?.bundles?.includes(def.package) ?? false;
  if (registered === !!args.uninstall) throw new Error('Official bundle registration verification failed');
  console.log(JSON.stringify({ package: def.package, registered, source: specifier, backup }, null, 2));
}
module.exports = { main, rewrite, argumentsOf, definitions };
