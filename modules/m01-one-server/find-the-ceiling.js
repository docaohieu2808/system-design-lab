// Module 1: step the arrival rate up and find where one server stops keeping up.
// Open model (constant-arrival-rate): k6 sends at the asked rate whether or not answers come back,
// so a slow server shows up as latency and dropped iterations instead of being hidden.
// Per-step numbers come from tagged sub-metrics; handleSummary writes them to RESULT (JSON).
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE || 'http://app:8080';
const STEPS = (__ENV.STEPS || '250,500,750,1000,1250,1500,2000,3000,4000,5000').split(',').map(Number);
const HOLD = Number(__ENV.HOLD || 20); // seconds per step
const GAP = Number(__ENV.GAP || 5);    // quiet seconds between steps
const RESULT = __ENV.RESULT || 'results/run.json';
const PREFIX = __ENV.PREFIX || '';               // 'page/' asks for the preview page instead of the redirect (Module 3)
const EXPECT = Number(__ENV.EXPECT || 302);      // the status a correct answer has

const scenarios = {};
const thresholds = {};
for (const [i, rate] of STEPS.entries()) {
  const name = `rps_${rate}`;
  scenarios[name] = {
    executor: 'constant-arrival-rate', rate, timeUnit: '1s', duration: `${HOLD}s`,
    startTime: `${i * (HOLD + GAP)}s`, preAllocatedVUs: Math.min(rate, 500), maxVUs: 3000,
  };
  // always-true thresholds: they only make k6 report each step's sub-metrics in the summary
  thresholds[`http_req_duration{scenario:${name}}`] = ['max>=0'];
  thresholds[`http_reqs{scenario:${name}}`] = ['count>=0'];
  thresholds[`http_req_failed{scenario:${name}}`] = ['rate>=0'];
  thresholds[`checks{scenario:${name}}`] = ['rate>=0'];
  thresholds[`dropped_iterations{scenario:${name}}`] = ['count>=0'];
}

export const options = {
  maxRedirects: 0, // measure our redirect, never follow it to the long URL
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
  scenarios, thresholds,
};

const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function b62(n) { let s = ''; while (n > 0) { s = A[n % 62] + s; n = Math.floor(n / 62); } return s; }

export default function () {
  const res = http.get(`${BASE}/${PREFIX}${b62(1 + Math.floor(Math.random() * 100000))}`,
    { timeout: '3s', tags: { name: 'GET /{code}' } });
  check(res, { redirected: (r) => r.status === EXPECT });
}

export function handleSummary(data) {
  const m = data.metrics, steps = [];
  const v = (k, f) => (m[k] ? m[k].values[f] : 0);
  for (const rate of STEPS) {
    const s = `{scenario:rps_${rate}}`;
    const completed = v(`http_reqs${s}`, 'count');
    steps.push({
      asked_rps: rate,
      sent_rps: +(completed / HOLD).toFixed(1),                       // requests k6 actually issued and got an answer or timeout for
      dropped: v(`dropped_iterations${s}`, 'count'),                    // requests k6 could not even send (no free VU)
      completed_rps: +((completed * (1 - v(`http_req_failed${s}`, 'rate'))) / HOLD).toFixed(1),
      succeeded_rps: +((completed * v(`checks${s}`, 'rate')) / HOLD).toFixed(1), // got the expected 302
      p50_ms: +v(`http_req_duration${s}`, 'p(50)').toFixed(2),
      p95_ms: +v(`http_req_duration${s}`, 'p(95)').toFixed(2),
      p99_ms: +v(`http_req_duration${s}`, 'p(99)').toFixed(2),
      avg_ms: +v(`http_req_duration${s}`, 'avg').toFixed(2),
      max_ms: +v(`http_req_duration${s}`, 'max').toFixed(2),
    });
  }
  return { [RESULT]: JSON.stringify({ hold_s: HOLD, steps }, null, 1), stdout: `steps written to ${RESULT}\n` };
}
