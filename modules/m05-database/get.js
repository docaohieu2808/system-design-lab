// Module 5: a steady open load on one GET endpoint. PATH may contain {id} (a random link id) or {code} (its short code).
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE || 'http://app:8080';
const PATH = __ENV.PATH_TMPL || '/api/recent';
const RATE = Number(__ENV.RATE || 100);
const DURATION = Number(__ENV.DURATION || 30);
const MAXID = Number(__ENV.MAXID || 1000000);
const RESULT = __ENV.RESULT || 'results/run.json';

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'p(50)', 'p(99)', 'max'],
  scenarios: { load: { executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: `${DURATION}s`,
    preAllocatedVUs: 200, maxVUs: 2000 } },
};
const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function b62(n) { let s = ''; while (n > 0) { s = A[n % 62] + s; n = Math.floor(n / 62); } return s; }

export default function () {
  const id = 1 + Math.floor(Math.random() * MAXID);
  const res = http.get(BASE + PATH.replace('{id}', id).replace('{code}', b62(id)), { timeout: '10s' });
  check(res, { ok: (r) => r.status === 200 });
}

export function handleSummary(data) {
  const m = data.metrics, d = m.http_req_duration.values, n = m.http_reqs.values.count;
  return { [RESULT]: JSON.stringify({ path: PATH, rate: RATE, requests: n, rps: +(n / DURATION).toFixed(1),
    failed_pct: +(100 * (1 - m.checks.values.rate)).toFixed(3), dropped: m.dropped_iterations ? m.dropped_iterations.values.count : 0,
    p50_ms: +d['p(50)'].toFixed(2), p99_ms: +d['p(99)'].toFixed(2), max_ms: +d.max.toFixed(2) }, null, 1),
    stdout: `written to ${RESULT}\n` };
}
