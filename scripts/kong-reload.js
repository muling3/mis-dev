#!/usr/bin/env node
// Reload Kong's declarative config (DB-less). Replaces:
//   curl -s -X POST :8001/config -F config=@docker/kong/kong.yml | head -c 400

'use strict';

const fs = require('node:fs');
const path = require('node:path');

(async () => {
  const cfg = fs.readFileSync(path.join(__dirname, '..', 'docker', 'kong', 'kong.yml'));
  const fd = new FormData();
  fd.append('config', new Blob([cfg]), 'kong.yml');

  let res;
  try {
    res = await fetch('http://localhost:8001/config', { method: 'POST', body: fd });
  } catch (e) {
    console.error(`✗ Kong admin API unreachable at :8001 (${e.message}).`);
    console.error('  Is infra up? Run: make infra-up');
    process.exit(1);
  }
  const text = await res.text();
  process.stdout.write(text.slice(0, 400) + '\n');
})();
