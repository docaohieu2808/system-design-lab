// Module 9: one client calling a rate-limited endpoint (limit: 10 per second).
//   TEST=steady    50 requests per second for 30 s, counted in three 10-second phases (before / during / after a
//                  Redis outage the runner may cause in the middle)
//   TEST=boundary  20 requests in the last 100 ms of a second, 20 more in the first 100 ms of the next; 5 times
//   SPOOF=1        every request claims a different address in X-Forwarded-For
import http from 'k6/http';
import { sleep } from 'k6';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://traefik:80', TEST = __ENV.TEST || 'steady', SPOOF = __ENV.SPOOF === '1';
const RESULT = __ENV.RESULT || 'results/run.json';
const codes = { 200: new Counter('c200'), 429: new Counter('c429'), 503: new Counter('c503') }, other = new Counter('cother');
const phase = (name, start) => ({ executor: 'constant-arrival-rate', rate: 50, timeUnit: '1s', duration: '10s',
  startTime: `${start}s`, preAllocatedVUs: 50, maxVUs: 200, tags: { phase: name } });
export const options = TEST === 'steady'
  ? { scenarios: { before: phase('before', 0), during: phase('during', 10), after: phase('after', 20) },
      thresholds: Object.fromEntries(['before', 'during', 'after'].flatMap((p) =>
        ['c200', 'c429', 'c503', 'cother'].map((c) => [`${c}{phase:${p}}`, ['count>=0']]))) }
  : { scenarios: { b: { executor: 'per-vu-iterations', vus: 1, iterations: 5, maxDuration: '60s' } } };

function call() {
  const headers = SPOOF ? { 'X-Forwarded-For': `203.0.113.${Math.floor(Math.random() * 250)}` } : {};
  const r = http.get(`${BASE}/api/limited`, { headers, timeout: '3s' });
  (codes[r.status] || other).add(1);
  return r.status;
}

export default function () {
  if (TEST === 'steady') { call(); return; }
  // wait for 900 ms into a second, then two bursts straddling the boundary
  sleep(((1900 - (Date.now() % 1000)) % 1000) / 1000);
  http.batch(Array.from({ length: 20 }, () => ['GET', `${BASE}/api/limited`, null, { timeout: '3s' }])).forEach((r) => (codes[r.status] || other).add(1));
  sleep(Math.max(0, (1000 - (Date.now() % 1000)) / 1000));
  http.batch(Array.from({ length: 20 }, () => ['GET', `${BASE}/api/limited`, null, { timeout: '3s' }])).forEach((r) => (codes[r.status] || other).add(1));
  sleep(2);
}

export function handleSummary(data) {
  const v = (k) => (data.metrics[k] ? data.metrics[k].values.count : 0), out = { test: TEST, spoof: SPOOF };
  if (TEST === 'steady') {
    for (const p of ['before', 'during', 'after']) {
      out[p] = { allowed_per_s: v(`c200{phase:${p}}`) / 10, refused_429: v(`c429{phase:${p}}`), errors_503: v(`c503{phase:${p}}`), other: v(`cother{phase:${p}}`) };
    }
  } else {
    out.allowed_per_burst_pair = v('c200') / 5; out.refused = v('c429');
  }
  return { [RESULT]: JSON.stringify(out, null, 1), stdout: `written to ${RESULT}\n` };
}
