#!/usr/bin/env node
// Stop every background service started by `up-all`, then bring infra down.
// Reads PID files from $PIDDIR (default /tmp on POSIX, %TEMP% on Windows).

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { MIS_DEV, SERVICES, PIDDIR, killPid, run } = require('./_lib');

for (const domain of Object.keys(SERVICES)) {
  const pidPath = path.join(PIDDIR, `mis-${domain}.pid`);
  if (!fs.existsSync(pidPath)) continue;
  const pid = Number(fs.readFileSync(pidPath, 'utf8').trim());
  if (pid && killPid(pid)) console.log(`  stopped ${domain} (pid ${pid})`);
  try { fs.unlinkSync(pidPath); } catch {}
}

run('make', ['-C', MIS_DEV, 'infra-down']);
