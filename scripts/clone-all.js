#!/usr/bin/env node
// Clone every MIS repo into the parent directory next to mis-dev.
//
// Default URLs come from repos.txt (every line except mis-dev). Override
// with a single CSV argv, e.g.:
//   node scripts/clone-all.js git@.../a.git,git@.../b.git

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { PARENT, readRepos } = require('./_lib');

const arg = (process.argv[2] || '').trim();
const urls = arg
  ? arg.split(',').map((s) => s.trim()).filter(Boolean)
  : readRepos().filter((r) => r.name !== 'mis-dev').map((r) => r.url);

for (const url of urls) {
  const dir = path.basename(url, '.git');
  const target = path.join(PARENT, dir);
  if (fs.existsSync(path.join(target, '.git'))) {
    console.log(`  exists  ${dir}`);
    continue;
  }
  console.log(`  clone   ${dir}`);
  const r = spawnSync('git', ['clone', '-q', url, target], { stdio: 'inherit' });
  if (r.status !== 0) console.log(`  FAILED  ${dir}`);
}
