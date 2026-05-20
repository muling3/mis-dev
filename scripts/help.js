#!/usr/bin/env node
// Parse the Makefile's `## help` comments and print them, replacing the
// `awk` recipe used in the original Makefile.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const text = fs.readFileSync(path.join(__dirname, '..', 'Makefile'), 'utf8');
for (const line of text.split(/\r?\n/)) {
  const m = line.match(/^([a-zA-Z_-]+):.*?## (.*)$/);
  if (m) console.log(`  ${m[1].padEnd(16)} ${m[2]}`);
}
