// Module 11: 200 page views per second for 30 s; each page also asks a dependency that has become slow.
import http from 'k6/http';
import { Counter } from 'k6/metrics';
const BASE = __ENV.BASE || 'http://app:8080', RESULT = __ENV.RESULT || 'results/run.json';
const degraded = new Counter('degraded'), ok = new Counter('ok');
export const options = { discardResponseBodies: true, summaryTrendStats: ['p(50)', 'p(99)', 'max'],
  scenarios: { load: { executor: 'constant-arrival-rate', rate: 200, timeUnit: '1s', duration: '30s', preAllocatedVUs: 300, maxVUs: 3000 } } };
const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function b62(n) { let s = ''; while (n > 0) { s = A[n % 62] + s; n = Math.floor(n / 62); } return s; }
export default function () {
  const r = http.get(`${BASE}/api/enrich/${b62(1 + Math.floor(Math.random() * 100000))}`, { timeout: '5s' });
  if (r.status === 200) { ok.add(1); if (r.headers['X-Degraded'] === '1') degraded.add(1); }
}
export function handleSummary(data) {
  const m = data.metrics, d = m.http_req_duration.values, n = m.http_reqs.values.count, v = (k) => (m[k] ? m[k].values.count : 0);
  return { [RESULT]: JSON.stringify({ requests: n, ok_pct: +(100 * v('ok') / n).toFixed(2), degraded_pct: +(100 * v('degraded') / n).toFixed(2),
    p50_ms: +d['p(50)'].toFixed(1), p99_ms: +d['p(99)'].toFixed(1), dropped: m.dropped_iterations ? m.dropped_iterations.values.count : 0 }, null, 1),
    stdout: `written to ${RESULT}\n` };
}
