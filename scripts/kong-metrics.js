#!/usr/bin/env node
// Print Kong's Prometheus metrics for HTTP requests and latency.
// Replaces:  curl -s :8100/metrics | grep -E '^kong_(...)' | head -20

'use strict';

const RE = /^kong_(http_requests_total|request_latency)/;
const NO_METRICS =
  'no metrics yet — is infra up and has traffic flowed through Kong?';

(async () => {
  let res;
  try {
    res = await fetch('http://localhost:8100/metrics');
  } catch {
    console.log(NO_METRICS);
    return;
  }
  if (!res.ok) {
    console.log(NO_METRICS);
    return;
  }
  const lines = (await res.text())
    .split(/\r?\n/)
    .filter((l) => RE.test(l))
    .slice(0, 20);
  console.log(lines.length ? lines.join('\n') : NO_METRICS);
})();
