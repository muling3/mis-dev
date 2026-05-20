#!/usr/bin/env node
// Run ONE service through Kong: ensure it's cloned and its deps installed,
// bring up infra, then `make dev` in the service repo with PORT injected.
//
// Usage:  node scripts/dev.js <auth|registration|case|sandbox|notification|document|admin>

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {
  MIS_DEV,
  PARENT,
  SERVICES,
  SERVICE_NAMES,
  readRepos,
  run,
  runOrExit,
} = require('./_lib');

const s = (process.argv[2] || '').trim();
if (!s) {
  console.error(`usage: make dev s=<${SERVICE_NAMES.join('|')}>`);
  process.exit(1);
}
const svc = SERVICES[s];
if (!svc) {
  console.error(`unknown service '${s}'. one of: ${SERVICE_NAMES.join('|')}`);
  process.exit(1);
}

const dirPath = path.join(PARENT, svc.dir);

// Clone if missing.
if (!fs.existsSync(path.join(dirPath, '.git'))) {
  const entry = readRepos().find((r) => r.name === `mis-${s}-service`);
  if (!entry) {
    console.error(`no repo URL for mis-${s}-service in repos.txt`);
    process.exit(1);
  }
  console.log(`→ cloning ${svc.dir}`);
  runOrExit('git', ['clone', '-q', entry.url, dirPath]);
}

// Install deps if missing.
if (!fs.existsSync(path.join(dirPath, 'node_modules'))) {
  console.log(`→ installing deps (${svc.dir})`);
  runOrExit('make', ['-C', dirPath, 'install-standalone']);
}

// Bring up infra.
runOrExit('make', ['-C', MIS_DEV, 'infra-up']);

console.log(`→ ${s} on :${svc.port}  (via Kong: http://localhost:8000/api/${s}/health)`);
process.exit(
  run('make', ['-C', dirPath, 'dev'], {
    env: { ...process.env, PORT: String(svc.port) },
  }),
);
