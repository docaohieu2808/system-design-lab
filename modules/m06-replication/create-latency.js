// Module 6: what does a create cost? Open model: POST /api/links at a fixed rate for DURATION seconds and record how long the
// answers take. Used for asynchronous vs synchronous (remote_apply) replication, and for "the synchronous standby is stopped".
// Latency is taken over the answers that were 201 only; every other answer, and every timeout, is counted separately.
// A "dropped" arrival (no free VU) would be a lab bug: the run is invalid and must be repeated with more VUs.
import http from 'k6/http';
import { Trend, Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://app:8080';
const RATE = Number(__ENV.RATE || 200);
const DURATION = Number(__ENV.DURATION || 30);
const TIMEOUT = __ENV.TIMEOUT || '5s';
const RESULT = __ENV.RESULT || 'results/run.json';
const okMs = new Trend('create_ok_ms', true), ok = new Counter('create_ok'), bad = new Counter('create_not_201'), slow = new Counter('create_timeout');

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
  scenarios: { load: { executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: `${DURATION}s`,
    preAllocatedVUs: Number(__ENV.VUS || 300), maxVUs: Number(__ENV.MAXVUS || 3000) } },
};

export default function () {
  const r = http.post(`${BASE}/api/links`, JSON.stringify({ url: `https://example.com/c/${__VU}-${__ITER}` }),
    { headers: { 'Content-Type': 'application/json' }, timeout: TIMEOUT });
  if (r.status === 201) { ok.add(1); okMs.add(r.timings.duration); }
  else if (r.status === 0) slow.add(1);   // k6 reports a timeout or connection error as status 0
  else bad.add(1);
}

export function handleSummary(data) {
  const m = data.metrics, c = (k) => (m[k] ? m[k].values.count : 0), t = (f) => (m.create_ok_ms ? +m.create_ok_ms.values[f].toFixed(2) : null);
  return { [RESULT]: JSON.stringify({ asked_rps: RATE, duration_s: DURATION, succeeded: c('create_ok'), succeeded_rps: +(c('create_ok') / DURATION).toFixed(1),
    not_201: c('create_not_201'), timeouts: c('create_timeout'), dropped: c('dropped_iterations'), max_vus: m.vus_max ? m.vus_max.values.max : null,
    p50_ms: t('p(50)'), p95_ms: t('p(95)'), p99_ms: t('p(99)'), avg_ms: t('avg'), max_ms: t('max') }, null, 1), stdout: `written to ${RESULT}\n` };
}
