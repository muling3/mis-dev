#!/usr/bin/env node
// List every MIS repo + its clone URL, from repos.txt.

'use strict';

const { readRepos } = require('./_lib');

console.log(
  'Clone mis-dev (this repo) for infra/docs; clone the ONE service you work on:',
);
console.log();
for (const { name, url } of readRepos()) {
  console.log(`  ${name.padEnd(26)} ${url}`);
}
