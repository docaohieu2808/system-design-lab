// Capstone 13.1 checker, load part: a steady open load of RATE redirects per second for 30 s against links the
// checker created, then the module-two goals: the slowest 1 in 100 under 50 ms, and no errors.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE || 'http://localhost:8080', RATE = Number(__ENV.RATE || 500), RESULT = __ENV.RESULT || 'check.json';
export const options = {
  maxRedirects: 0, discardResponseBodies: true, summaryTrendStats: ['p(50)', 'p(99)'],
  scenarios: { load: { executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: '30s', preAllocatedVUs: 200, maxVUs: 2000 } },
  thresholds: { http_req_duration: ['p(99)<50'], checks: ['rate>=0.999'] },
};
export function setup() {
  const codes = [];
  for (let i = 0; i < 200; i++) {
    const r = http.post(`${BASE}/api/links`, JSON.stringify({ url: `https://example.com/check/${i}` }), { headers: { 'Content-Type': 'application/json' } });
    if (r.status === 201) codes.push(r.json('code'));
  }
  return { codes };
}
export default function (d) {
  const i = Math.floor(Math.random() * d.codes.length);
  const r = http.get(`${BASE}/${d.codes[i]}`);
  check(r, { redirect: (x) => x.status === 302 && x.headers.Location === `https://example.com/check/${i}` });
}
export function handleSummary(data) {
  const m = data.metrics;
  const out = { rate: RATE, p99_ms: +m.http_req_duration.values['p(99)'].toFixed(2), correct_pct: +(100 * m.checks.values.rate).toFixed(2),
    dropped: m.dropped_iterations ? m.dropped_iterations.values.count : 0 };
  out.pass = out.p99_ms < 50 && out.correct_pct >= 99.9 && out.dropped === 0;
  return { [RESULT]: JSON.stringify(out, null, 1), stdout: `${out.pass ? 'PASS' : 'FAIL'} p99 ${out.p99_ms} ms, correct ${out.correct_pct}%, dropped ${out.dropped}\n` };
}
