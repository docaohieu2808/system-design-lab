// Module 3: a steady open load on the preview page, measured separately before and after something happens halfway
// (a copy is killed, frozen or slow). The event itself is done from outside by tools/run-m03.sh.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE || 'http://traefik:80';
const RATE = Number(__ENV.RATE || 600);
const HALF = Number(__ENV.HALF || 30);
const RESULT = __ENV.RESULT || 'results/run.json';

const phase = (name, start) => ({ executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: `${HALF}s`,
  startTime: `${start}s`, preAllocatedVUs: 500, maxVUs: 3000, tags: { phase: name } });
export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'p(50)', 'p(99)', 'max'],
  scenarios: { before: phase('before', 0), after: phase('after', HALF) },
  thresholds: Object.fromEntries(['before', 'after'].flatMap((p) => [
    [`http_req_duration{phase:${p}}`, ['max>=0']], [`http_reqs{phase:${p}}`, ['count>=0']],
    [`checks{phase:${p}}`, ['rate>=0']], [`dropped_iterations{phase:${p}}`, ['count>=0']]])),
};

const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function b62(n) { let s = ''; while (n > 0) { s = A[n % 62] + s; n = Math.floor(n / 62); } return s; }

export default function () {
  const res = http.get(`${BASE}/page/${b62(1 + Math.floor(Math.random() * 100000))}`, { timeout: '3s', tags: { name: 'GET /page/{code}' } });
  check(res, { ok: (r) => r.status === 200 });
}

export function handleSummary(data) {
  const m = data.metrics, v = (k, f) => (m[k] ? m[k].values[f] : 0), out = { rate: RATE, half_s: HALF };
  for (const p of ['before', 'after']) {
    const s = `{phase:${p}}`, n = v(`http_reqs${s}`, 'count');
    out[p] = { requests: n, failed: Math.round(n * (1 - v(`checks${s}`, 'rate'))), dropped: v(`dropped_iterations${s}`, 'count'),
      p50_ms: +v(`http_req_duration${s}`, 'p(50)').toFixed(2), p99_ms: +v(`http_req_duration${s}`, 'p(99)').toFixed(2),
      max_ms: +v(`http_req_duration${s}`, 'max').toFixed(2) };
  }
  return { [RESULT]: JSON.stringify(out, null, 1), stdout: `written to ${RESULT}\n` };
}
