'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const run = promisify(execFile);

async function fingerprint(source) {
  const hash = createHash('sha256').update(process.arch);
  async function visit(relative) {
    const file = path.join(source, relative);
    if ((await fs.stat(file)).isDirectory()) {
      for (const name of (await fs.readdir(file)).sort()) await visit(path.join(relative, name));
    } else hash.update(relative).update(await fs.readFile(file));
  }
  for (const relative of ['package.json', 'native', 'scripts/build.sh']) await visit(relative);
  return hash.digest('hex');
}

async function buildHelper(source, output, bundleId) {
  await run('sh', [path.join(source, 'scripts/build.sh'), output], {
    env: { ...process.env, DSH_SELECTION_BUNDLE_ID: bundleId, DSH_SELECTION_TMP: path.join(output, '.cache') },
    maxBuffer: 4 * 1024 * 1024,
  });
}

// Run before spawning the helper, including after a DSH package-manager update.
// Build and self-test first; retain the old application if either step fails.
async function ensureHelper(source, executable, build = buildHelper) {
  if (!executable.endsWith(path.join('DSH Selection.app', 'Contents', 'MacOS', 'DSHSelection'))) {
    return; // Explicit developer executables are managed by their owner.
  }
  const app = path.resolve(executable, '../../..');
  const parent = path.dirname(app);
  const stamp = `${app}.source-sha256`;
  const expected = await fingerprint(source);
  try {
    if ((await fs.readFile(stamp, 'utf8')) === expected) {
      await fs.access(executable, 1);
      return;
    }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await fs.mkdir(parent, { recursive: true });
  const lock = `${app}.update-lock`;
  await fs.mkdir(lock); // Refuse concurrent replacement of a shared helper path.
  let temporary;
  try {
    temporary = await fs.mkdtemp(path.join(parent, '.selection-update-'));
    let exists = false;
    let bundleId = 'local.dsh.selection-toolbar';
    try { await fs.access(app); exists = true; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (exists) {
      const result = await run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', path.join(app, 'Contents/Info.plist')]);
      bundleId = result.stdout.trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9.-]+$/.test(bundleId)) throw new Error('Invalid existing helper identity');
    }
    await build(source, temporary, bundleId);
    const next = path.join(temporary, 'DSH Selection.app');
    await fs.access(path.join(next, 'Contents/MacOS/DSHSelection'), 1);
    const backup = `${app}.backup-${path.basename(temporary)}`;
    if (exists) await fs.rename(app, backup);
    try { await fs.rename(next, app); }
    catch (error) {
      if (exists) await fs.rename(backup, app);
      throw error;
    }
    await fs.writeFile(stamp, expected);
  } finally {
    if (temporary) await fs.rm(temporary, { recursive: true, force: true });
    await fs.rmdir(lock);
  }
}
module.exports = { ensureHelper, fingerprint };
