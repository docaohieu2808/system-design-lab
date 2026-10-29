// Module 0: the same server, the same 2-second freeze, measured two ways.
// closed (constant-vus): each virtual user waits for its answer before sending the next request, so while the server is
//   frozen almost nothing is sent, and the freeze shows up as a handful of slow samples (coordinated omission).
// open (constant-arrival-rate): requests keep arriving on schedule whether or not answers come back, like real users,
//   so every request that arrives during the freeze is counted with its wait.
// The freeze itself is done from outside by tools/freeze-app.sh (docker pause), not by k6.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE || 'http://app:8080';
const MODEL = __ENV.MODEL || 'open';
const RATE = Number(__ENV.RATE || 800);      // open: requests per second
const VUS = Number(__ENV.VUS || 10);          // closed: users, each pausing THINK seconds between requests
const THINK = Number(__ENV.THINK || 0.01);
const DURATION = __ENV.DURATION || '60s';
const RESULT = __ENV.RESULT || 'results/run.json';

const scenario = MODEL === 'closed'
  ? { executor: 'constant-vus', vus: VUS, duration: DURATION }
  : { executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: DURATION, preAllocatedVUs: 2500, maxVUs: 4000 };

export const options = {
  maxRedirects: 0,
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'p(50)', 'p(99)', 'p(99.9)', 'max'],
  scenarios: { load: scenario },
  thresholds: { 'http_req_duration{slow:yes}': ['max>=0'] },
};

const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function b62(n) { let s = ''; while (n > 0) { s = A[n % 62] + s; n = Math.floor(n / 62); } return s; }

export default function () {
  const res = http.get(`${BASE}/${b62(1 + Math.floor(Math.random() * 100000))}`, { timeout: '5s', tags: { name: 'GET /{code}' } });
  check(res, { redirected: (r) => r.status === 302 });
  if (MODEL === 'closed') sleep(THINK);
}

export function handleSummary(data) {
  const m = data.metrics, d = m.http_req_duration.values, n = m.http_reqs.values.count;
  const secs = parseFloat(DURATION);
  const out = {
    model: MODEL, requests: n, rps: +(n / secs).toFixed(1),
    dropped: m.dropped_iterations ? m.dropped_iterations.values.count : 0,
    failed_pct: +(100 * m.http_req_failed.values.rate).toFixed(3),
    p50_ms: +d['p(50)'].toFixed(2), p99_ms: +d['p(99)'].toFixed(2), p999_ms: +d['p(99.9)'].toFixed(2),
    avg_ms: +d.avg.toFixed(2), max_ms: +d.max.toFixed(2),
  };
  return { [RESULT]: JSON.stringify(out, null, 1), stdout: `${MODEL}: written to ${RESULT}\n` };
}
