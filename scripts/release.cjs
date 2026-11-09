'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const assert = require('node:assert/strict');
const yaml = require('yaml');

function validateMetadata(manifest, patch, tag = '', plist = '') {
  assert.match(manifest.version, /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/, 'Only stable versions are published');
  if (tag) assert.equal(tag, `v${manifest.version}`, 'Release tag must match package.json');
  assert.equal(manifest.private, undefined, 'Package must be publishable');
  assert.equal(manifest.publishConfig?.access, 'public');
  assert.equal(manifest.publishConfig?.registry, 'https://registry.npmjs.org/');
  assert.equal(patch[0]?.insert?.[0]?.name, manifest.name, 'Bundle must load its own npm package');
  const repository = manifest.repository.url.replace(/^git\+/, '').replace(/\.git$/, '');
  assert.equal(repository, `https://github.com/jswalter/${manifest.name.split('/')[1]}`);
  if (plist) assert.equal(plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1], manifest.version, 'Native and npm versions must match');
}
function npm(args) {
  return spawnSync(process.platform === 'win32' ? 'npm.cmd' : 'npm', args, {
    encoding: 'utf8', maxBuffer: 8 * 1024 * 1024,
    env: { ...process.env, NPM_CONFIG_REGISTRY: 'https://registry.npmjs.org/' },
  });
}
function checked(args) {
  const result = npm(args);
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || String(result.error));
  return result.stdout;
}
function publishedIntegrity(name, version) {
  const result = npm(['view', `${name}@${version}`, 'dist.integrity', '--json', '--prefer-online', '--fetch-retries=0', '--fetch-timeout=15000']);
  if (result.status === 0) {
    const value = JSON.parse(result.stdout);
    return Array.isArray(value) ? value[0] : value;
  }
  let detail;
  try { detail = JSON.parse(result.stdout); } catch { /* Refuse an unknown/network failure. */ }
  if (detail?.error?.code === 'E404') return null;
  throw new Error(result.stderr || result.stdout || String(result.error));
}
async function main() {
  const publish = process.argv.includes('--publish');
  const root = path.resolve(__dirname, '..');
  process.chdir(root);
  const manifest = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  const tag = process.env.RELEASE_TAG || '';
  if (publish) assert.ok(tag, 'Publishing requires a GitHub Release tag');
  const plist = fs.existsSync('native/Info.plist') ? fs.readFileSync('native/Info.plist', 'utf8') : '';
  validateMetadata(manifest, yaml.parse(fs.readFileSync('cordis.patch.yml', 'utf8')), tag, plist);
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-release-'));
  try {
    const result = JSON.parse(checked(['pack', '--json', '--ignore-scripts', '--pack-destination', temporary]));
    const pack = Array.isArray(result) ? result[0] : result[manifest.name];
    assert.equal(pack.name, manifest.name);
    assert.equal(pack.version, manifest.version);
    const files = new Set(pack.files.map(file => file.path));
    for (const required of ['package.json', 'index.mjs', 'cordis.patch.yml', 'install.command', 'scripts/plugin-installer.cjs']) assert.ok(files.has(required), `Missing ${required}`);
    if (plist) for (const required of ['client.js', 'config.mjs', 'scripts/helper-sync.cjs', 'scripts/build.sh', 'native/main.swift', 'native/Info.plist']) assert.ok(files.has(required), `Missing ${required}`);
    console.log(`Validated ${manifest.name}@${manifest.version}: ${files.size} packed files`);
    if (!publish) return;
    const existing = publishedIntegrity(manifest.name, manifest.version);
    if (existing) {
      assert.equal(existing, pack.integrity, 'Published version differs; increment the version instead of replacing it');
      console.log('This exact package is already published; nothing to upload.');
      return;
    }
    console.log(checked(['publish', path.join(temporary, pack.filename), '--access=public', '--provenance', '--tag=latest', '--ignore-scripts']));
    // npm scans new versions before serving them. Do not report success until DSH can retrieve this version.
    for (let attempt = 0; attempt < 40; attempt++) {
      const integrity = publishedIntegrity(manifest.name, manifest.version);
      if (integrity) {
        assert.equal(integrity, pack.integrity, 'Registry integrity must match the tested tarball');
        console.log(`Available on npm: ${manifest.name}@${manifest.version}`);
        return;
      }
      console.log('Waiting for npm publish scanning (30 seconds)...');
      await new Promise(resolve => setTimeout(resolve, 30000));
    }
    throw new Error('npm accepted the upload but it is not yet installable; check npm processing status before retrying');
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
}
module.exports = { validateMetadata };
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
