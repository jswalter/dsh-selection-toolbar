'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { validateMetadata } = require('../scripts/release.cjs');
const manifest = { name: '@jswalter/dsh-example', version: '1.2.3', repository: { url: 'https://github.com/jswalter/dsh-example.git' }, publishConfig: { access: 'public', registry: 'https://registry.npmjs.org/' } };
const patch = [{ insert: [{ name: manifest.name }] }];
test('release accepts matching stable tags and rejects mismatches or prereleases', () => {
 validateMetadata(manifest, patch, 'v1.2.3');
 for (const tag of ['v1.2.4', '1.2.3', 'v1.2.3; echo bad']) assert.throws(() => validateMetadata(manifest, patch, tag));
 assert.throws(() => validateMetadata({ ...manifest, version: '1.2.3-beta.1' }, patch));
});
test('release rejects broken bundle registration and native version drift', () => {
 assert.throws(() => validateMetadata(manifest, [{ insert: [{ name: 'wrong' }] }]));
 assert.throws(() => validateMetadata(manifest, patch, '', '<key>CFBundleShortVersionString</key><string>1.2.2</string>'));
 validateMetadata(manifest, patch, 'v1.2.3', '<key>CFBundleShortVersionString</key><string>1.2.3</string>');
});
