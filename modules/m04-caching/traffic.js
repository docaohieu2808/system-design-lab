// Module 4: a steady open load on the preview page, with the codes chosen the way real traffic chooses them.
//   KEYS=zipf     a few links get most of the clicks: link k is picked with probability ~ 1/k (Zipf, s = 1)
//   KEYS=uniform  every one of the 100,000 links is equally likely
//   KEYS=hot      HOT_PCT percent of requests ask for one page (think: the home page), the rest are Zipf
// The app's own counters (GET /stats) say how many requests reached the database; tools/run-m04.sh reads them.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE || 'http://app:8080';
const RATE = Number(__ENV.RATE || 400);
const DURATION = Number(__ENV.DURATION || 60);
const KEYS = __ENV.KEYS || 'zipf';
const N = 100000;
const RESULT = __ENV.RESULT || 'results/run.json';

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'p(50)', 'p(99)', 'max'],
  scenarios: { load: { executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: `${DURATION}s`,
    preAllocatedVUs: 300, maxVUs: 2000 } },
};

const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function b62(n) { let s = ''; while (n > 0) { s = A[n % 62] + s; n = Math.floor(n / 62); } return s; }
// continuous inverse of the 1/k density on [1, N+1): close to Zipf(s = 1) without a 100,000-entry table per VU
const HOT_PCT = Number(__ENV.HOT_PCT || 50);
const zipf = () => Math.min(N, Math.floor(Math.exp(Math.random() * Math.log(N + 1))));
const pick = KEYS === 'uniform' ? () => 1 + Math.floor(Math.random() * N)
  : KEYS === 'hot' ? () => (Math.random() * 100 < HOT_PCT ? 1 : zipf()) : zipf;

export default function () {
  const res = http.get(`${BASE}/page/${b62(pick())}`, { timeout: '3s', tags: { name: 'GET /page/{code}' } });
  check(res, { ok: (r) => r.status === 200 });
}

export function handleSummary(data) {
  const m = data.metrics, d = m.http_req_duration.values, n = m.http_reqs.values.count;
  return { [RESULT]: JSON.stringify({ keys: KEYS, rate: RATE, requests: n, rps: +(n / DURATION).toFixed(1),
    failed_pct: +(100 * (1 - m.checks.values.rate)).toFixed(3), dropped: m.dropped_iterations ? m.dropped_iterations.values.count : 0,
    p50_ms: +d['p(50)'].toFixed(2), p99_ms: +d['p(99)'].toFixed(2), max_ms: +d.max.toFixed(2) }, null, 1),
    stdout: `written to ${RESULT}\n` };
}
