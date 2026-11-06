// Module 10, retry burst: N clients all send one create in the same moment while the app is down, fail together, and retry
// on the same schedule. The case jitter exists for.
//   JITTER=0   wait exactly 1 s, 2 s, 4 s, 8 s, 16 s between tries      (every client retries at the same instants)
//   JITTER=1   wait a random time between 0 and that cap ("full jitter") (retries spread out)
//   N          clients (default 300), one create each; RETRIES tries again after the first (default 5); BASE_MS first cap (1000)
// The runner stops the app before the test and starts it again about 10 s into the run. Attempts are counted per 100 ms
// of the test (BUCKETS of them), so the shape of the load on the app can be read; every client ends created or gave up.
import http from 'k6/http';
import exec from 'k6/execution';
import { sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://app:8080', N = Number(__ENV.N || 300), RETRIES = Number(__ENV.RETRIES || 5);
const BASE_MS = Number(__ENV.BASE_MS || 1000), JITTER = __ENV.JITTER === '1', RESULT = __ENV.RESULT || 'results/burst.json';
const BUCKETS = 400, BUCKET_MS = 100;   // 0 to 40 s in 100 ms steps; the last bucket collects anything later
const IDX = Array.from({ length: BUCKETS }, (_, i) => i);
const attempts = new Counter('attempts'), began = new Counter('began'), created = new Counter('created'), gaveUp = new Counter('gave_up');
const t0 = new Trend('t0_ms'), done = new Trend('done_s');
export const options = {
  dns: { ttl: '0' }, noConnectionReuse: true,
  summaryTrendStats: ['min', 'p(50)', 'p(99)', 'max'],
  scenarios: { burst: { executor: 'per-vu-iterations', vus: N, iterations: 1, maxDuration: '60s' } },
  thresholds: Object.fromEntries(IDX.map((i) => [`attempts{b:${i}}`, ['count>=0']])),
};
export default function () {
  began.add(1);
  t0.add(Date.now() - exec.instance.currentTestRunDuration);   // wall-clock start of the test; the summary keeps the smallest
  for (let i = 0; i <= RETRIES; i++) {
    attempts.add(1, { b: String(Math.min(BUCKETS - 1, Math.floor(exec.instance.currentTestRunDuration / BUCKET_MS))) });
    const r = http.post(`${BASE}/api/links`, JSON.stringify({ url: `https://example.com/b/${__VU}-${i}` }),
      { headers: { 'Content-Type': 'application/json' }, timeout: '2s' });
    if (r.status === 201) { created.add(1); done.add(exec.instance.currentTestRunDuration / 1000); return; }
    if (i === RETRIES) break;
    const cap = BASE_MS * 2 ** i;
    sleep((JITTER ? Math.random() * cap : cap) / 1000);
  }
  gaveUp.add(1);
  done.add(exec.instance.currentTestRunDuration / 1000);
}
export function handleSummary(data) {
  const v = (k) => (data.metrics[k] ? data.metrics[k].values.count : 0);
  const out = { jitter: JITTER, clients: N, retries: RETRIES, base_ms: BASE_MS, bucket_ms: BUCKET_MS,
    began: v('began'), created: v('created'), gave_up: v('gave_up'), attempts: v('attempts'),
    test_started_ms: Math.round(data.metrics.t0_ms ? data.metrics.t0_ms.values.min : 0),
    last_done_s: +data.metrics.done_s.values.max.toFixed(2),
    attempts_per_bucket: IDX.map((i) => v(`attempts{b:${i}}`)) };
  out.ended_other = out.began - out.created - out.gave_up;
  return { [RESULT]: JSON.stringify(out), stdout: `written to ${RESULT}\n` };
}
