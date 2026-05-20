#!/usr/bin/env node
// Lead-dev: infra + every cloned service running in the background.
// Writes a PID file per service into $PIDDIR so `down-all` can stop them.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {
  MIS_DEV,
  PARENT,
  SERVICES,
  PIDDIR,
  run,
  runOrExit,
  spawnDetached,
} = require('./_lib');

runOrExit('make', ['-C', MIS_DEV, 'infra-up']);

for (const [domain, { port, dir }] of Object.entries(SERVICES)) {
  const dirPath = path.join(PARENT, dir);
  if (!fs.existsSync(path.join(dirPath, '.git'))) {
    console.log(`  skip ${domain} (not cloned — make clone-all)`);
    continue;
  }
  if (!fs.existsSync(path.join(dirPath, 'node_modules'))) {
    runOrExit('make', ['-C', dirPath, 'install-standalone']);
  }
  // build is noisy — drop its output.
  run('make', ['-C', dirPath, 'build'], { stdio: 'ignore' });

  const logPath = path.join(PIDDIR, `mis-${domain}.log`);
  const pidPath = path.join(PIDDIR, `mis-${domain}.pid`);
  const pid = spawnDetached('node', ['dist/main.js'], {
    cwd: dirPath,
    env: { ...process.env, PORT: String(port) },
    logPath,
  });
  fs.writeFileSync(pidPath, String(pid));
  console.log(`  started ${domain} → :${port} (log: ${logPath})`);
}

console.log(
  'All up. Through Kong: http://localhost:8000/api/<domain>/...  —  stop: make down-all',
);
