#!/usr/bin/env node
// Mint a PoC HS256 JWT that Kong's `jwt` plugin will accept.
//
//   iss    = mis-auth   (matches kong.yml's jwt_secrets.key)
//   secret = $JWT_SECRET (matches docker-compose.yml's JWT_SECRET)
//
// Cross-platform: pure Node. No bash, openssl, awk, or tr needed.
//
// Usage:
//   node scripts/mint-token.js                     # prints the token
//   set TOKEN=...                                  # PowerShell/cmd
//   TOKEN=$(node scripts/mint-token.js)            # bash
//
// Env overrides: JWT_SECRET, JWT_TTL (seconds), JWT_SUB, JWT_ROLES (csv)

'use strict';

const { createHmac } = require('node:crypto');

const SECRET = process.env.JWT_SECRET || 'mis-poc-dev-secret-change-me';
const TTL = Number(process.env.JWT_TTL || 3600);
const SUB = process.env.JWT_SUB || 'u-001';
const ROLES = (process.env.JWT_ROLES || 'admin').split(',').map((s) => s.trim()).filter(Boolean);

const b64url = (input) => {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input, 'utf8');
  return buf
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
};

const now = Math.floor(Date.now() / 1000);
const exp = now + TTL;

const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
const payload = b64url(
  JSON.stringify({
    iss: 'mis-auth',
    sub: SUB,
    name: 'Dev User',
    email: 'dev@mis.local',
    roles: ROLES,
    iat: now,
    exp,
  }),
);

const sig = b64url(createHmac('sha256', SECRET).update(`${header}.${payload}`).digest());

process.stdout.write(`${header}.${payload}.${sig}\n`);
process.stderr.write(
  `minted JWT — sub=${SUB} roles=[${ROLES.join(',')}] exp in ${TTL}s (iss=mis-auth)\n`,
);
