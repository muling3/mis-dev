#!/usr/bin/env node
// Print docs/urls.txt — the local-URL cheat sheet.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

try {
  process.stdout.write(
    fs.readFileSync(path.join(__dirname, '..', 'docs', 'urls.txt'), 'utf8'),
  );
} catch {
  console.log('(docs/urls.txt missing)');
}
