#!/usr/bin/env node
// Create the minimum set of Kafka topics from the architecture docs.
// Cross-platform: pure Node. Calls `docker` directly via child_process — no
// shell, no bash, no coreutils required.
//
// Env overrides: KAFKA_CONTAINER, KAFKA_BROKER, KAFKA_READY_TIMEOUT (seconds)

'use strict';

const { spawnSync } = require('node:child_process');

const CONTAINER = process.env.KAFKA_CONTAINER || 'mis-dev-kafka-1';
const BROKER = process.env.KAFKA_BROKER || 'kafka:9092';
const READY_TIMEOUT = Number(process.env.KAFKA_READY_TIMEOUT || 90);

const TOPICS = [
  'mis.audit',
  'mis.dlq',
  'mis.cases',
  'mis.cases.sla',
  'mis.applications',
  'mis.documents',
  // Document-upload workflow: per-stage progress events + final verdict,
  // emitted by Sandbox Service and consumed by Document Service. See
  // architecture/document-upload-workflow.md.
  'mis.documents.scan-progress',
  'mis.documents.verdict',
  'mis.notifications',
  'mis.sandbox.verdicts',
];

const dockerExec = (cmd, args, { quiet = false } = {}) =>
  spawnSync('docker', ['exec', CONTAINER, cmd, ...args], {
    stdio: quiet ? 'pipe' : 'inherit',
    encoding: 'utf8',
  });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  process.stderr.write(`→ waiting for Kafka broker (${CONTAINER}) — up to ${READY_TIMEOUT}s\n`);

  const deadline = Date.now() + READY_TIMEOUT * 1000;
  // Loop until kafka-broker-api-versions succeeds or we hit the deadline.
  while (true) {
    const r = dockerExec(
      'kafka-broker-api-versions',
      ['--bootstrap-server', BROKER],
      { quiet: true },
    );
    if (r.status === 0) break;
    if (Date.now() >= deadline) {
      process.stderr.write(`✗ Kafka not ready after ${READY_TIMEOUT}s\n`);
      process.exit(1);
    }
    await sleep(3000);
  }
  process.stderr.write('✓ Kafka broker ready\n');

  for (const topic of TOPICS) {
    process.stderr.write(`→ creating ${topic}\n`);
    const r = dockerExec('kafka-topics', [
      '--bootstrap-server', BROKER,
      '--create', '--if-not-exists',
      '--topic', topic,
      '--partitions', '1',
      '--replication-factor', '1',
    ]);
    if (r.status !== 0) process.exit(r.status || 1);
  }

  // Final listing — proves what's actually on the broker.
  const list = dockerExec('kafka-topics', ['--bootstrap-server', BROKER, '--list']);
  process.exit(list.status || 0);
})().catch((err) => {
  process.stderr.write(`✗ ${err && err.message ? err.message : err}\n`);
  process.exit(1);
});
