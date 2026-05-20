// Shared helpers for the mis-dev Makefile-invoked Node scripts.
// Cross-platform: pure Node — no shell out for orchestration, only for the
// underlying tools the Makefile already required (docker, git, make, node).

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync, spawn } = require('node:child_process');

const HERE = __dirname;
const MIS_DEV = path.resolve(HERE, '..');
const PARENT = path.resolve(MIS_DEV, '..');

// domain → { port, dir }   (dir = basename of the repo's git URL, where the
// service ends up next to mis-dev after `make clone-all`).
const SERVICES = {
  auth:         { port: 3001, dir: 'mis-auth-svc' },
  registration: { port: 3002, dir: 'mis-registration-svc' },
  case:         { port: 3003, dir: 'mis-case-svc' },
  sandbox:      { port: 3004, dir: 'mis-sandbox-svc' },
  notification: { port: 3005, dir: 'mis-notification-svc' },
  document:     { port: 3007, dir: 'mis-document-svc' },
  admin:        { port: 3008, dir: 'mis-admin-svc' },
};

const SERVICE_NAMES = Object.keys(SERVICES);

// Where we drop logs + PID files for `up-all` / `down-all`. Pick a writable
// temp dir that exists on every platform.
const PIDDIR =
  process.env.PIDDIR ||
  (process.platform === 'win32'
    ? process.env.TEMP || process.env.TMP || 'C:\\Windows\\Temp'
    : '/tmp');

// Parse repos.txt — the canonical list of every MIS git repo.
function readRepos() {
  const file = path.join(MIS_DEV, 'repos.txt');
  return fs
    .readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'))
    .map((l) => {
      const [name, ...rest] = l.split(/\s+/);
      return { name, url: rest.join(' ') };
    })
    .filter((r) => r.name && r.url);
}

// `make`-equivalent: run a command, inherit IO, return exit code.
function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { stdio: 'inherit', ...opts });
  if (r.error) throw r.error;
  return r.status ?? 0;
}

// `make`-equivalent that exits the current process on failure.
function runOrExit(cmd, args, opts = {}) {
  const code = run(cmd, args, opts);
  if (code !== 0) process.exit(code);
}

// Spawn a background process that survives this Node script exiting, and
// return its PID. On Windows, `detached: true` puts the child in a new
// process group so it can outlive the parent.
function spawnDetached(cmd, args, { cwd, env, logPath }) {
  const log = fs.openSync(logPath, 'a');
  const child = spawn(cmd, args, {
    cwd,
    env,
    detached: true,
    stdio: ['ignore', log, log],
    windowsHide: true,
  });
  child.unref();
  return child.pid;
}

// Cross-platform "kill PID and don't error if it's already gone".
function killPid(pid) {
  try {
    if (process.platform === 'win32') {
      spawnSync('taskkill', ['/F', '/PID', String(pid)], { stdio: 'ignore' });
    } else {
      process.kill(pid);
    }
    return true;
  } catch {
    return false;
  }
}

module.exports = {
  HERE,
  MIS_DEV,
  PARENT,
  SERVICES,
  SERVICE_NAMES,
  PIDDIR,
  readRepos,
  run,
  runOrExit,
  spawnDetached,
  killPid,
};
