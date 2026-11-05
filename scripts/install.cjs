#!/usr/bin/env node
'use strict';
const installer = require('./plugin-installer.cjs');
module.exports = installer;
if (require.main === module) installer.main('selection').catch(error => { console.error(error.message); process.exitCode = 1; });
