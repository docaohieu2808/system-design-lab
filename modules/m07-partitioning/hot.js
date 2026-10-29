// Module 7: redirects at a steady rate; HOT_PCT percent of them ask for one single code (a celebrity's link).
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://app:8080', RATE = Number(__ENV.RATE || 1800), DURATION = Number(__ENV.DURATION || 30);
const HOT_PCT = Number(__ENV.HOT_PCT || 0), HOT = __ENV.HOT || '1C', RESULT = __ENV.RESULT || 'results/run.json';
const hotT = new Trend('hot_ms', true), coldT = new Trend('cold_ms', true);
export const options = {
  maxRedirects: 0, discardResponseBodies: true, summaryTrendStats: ['p(50)', 'p(99)', 'max'],
  scenarios: { load: { executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: `${DURATION}s`, preAllocatedVUs: 300, maxVUs: 3000 } },
};
const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function b62(n) { let s = ''; while (n > 0) { s = A[n % 62] + s; n = Math.floor(n / 62); } return s; }
export default function () {
  const hot = Math.random() * 100 < HOT_PCT;
  const res = http.get(`${BASE}/${hot ? HOT : b62(1 + Math.floor(Math.random() * 100000))}`, { timeout: '5s' });
  check(res, { ok: (r) => r.status === 302 });
  (hot ? hotT : coldT).add(res.timings.duration);
}
export function handleSummary(data) {
  const m = data.metrics, v = (k, f) => (m[k] ? +m[k].values[f].toFixed(2) : null), n = m.http_reqs.values.count;
  return { [RESULT]: JSON.stringify({ hot_pct: HOT_PCT, rate: RATE, rps: +(n / DURATION).toFixed(1),
    failed_pct: +(100 * (1 - m.checks.values.rate)).toFixed(3), dropped: m.dropped_iterations ? m.dropped_iterations.values.count : 0,
    p99_ms: v('http_req_duration', 'p(99)'), hot_p99_ms: v('hot_ms', 'p(99)'), cold_p50_ms: v('cold_ms', 'p(50)'),
    cold_p99_ms: v('cold_ms', 'p(99)') }, null, 1), stdout: `written to ${RESULT}\n` };
}
