// Module 10: users creating links at a steady rate.
//   RETRY=none | immediate | backoff   on a failed create, try again at once (up to 5 times) or after
//                                      200 ms, 400 ms, 800 ms ... with random jitter
// Counts every attempt, so retries show up as extra load. Phases: before / during / after an outage the runner causes.
import http from 'k6/http';
import { sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://app:8080', RATE = Number(__ENV.RATE || 40), RETRY = __ENV.RETRY || 'none';
const RESULT = __ENV.RESULT || 'results/run.json';
const attempts = new Counter('attempts'), created = new Counter('created'), gaveUp = new Counter('gave_up');
const t = new Trend('create_ms', true);
const phase = (name, start, dur) => ({ executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: `${dur}s`,
  startTime: `${start}s`, preAllocatedVUs: 200, maxVUs: 3000, tags: { phase: name } });
// With retries, look the app up again on every request and open a fresh connection, so a stopped app fails at once
// (k6 otherwise keeps the old address for 5 minutes and waits out the timeout on it, which hides the storm).
export const options = {
  ...(RETRY !== 'none' ? { dns: { ttl: '0' }, noConnectionReuse: true } : {}),
  summaryTrendStats: ['p(50)', 'p(99)', 'max'],
  scenarios: { before: phase('before', 0, 10), during: phase('during', 10, 10), after: phase('after', 20, 10) },
  thresholds: Object.fromEntries(['before', 'during', 'after'].flatMap((p) =>
    [[`attempts{phase:${p}}`, ['count>=0']], [`created{phase:${p}}`, ['count>=0']], [`gave_up{phase:${p}}`, ['count>=0']]])),
};
export default function () {
  const t0 = Date.now();
  for (let i = 0; i <= 5; i++) {
    attempts.add(1);
    const r = http.post(`${BASE}/api/links`, JSON.stringify({ url: `https://example.com/q/${__VU}-${__ITER}` }),
      { headers: { 'Content-Type': 'application/json' }, timeout: '2s' });
    if (r.status === 201) { created.add(1); t.add(Date.now() - t0); return; }
    if (RETRY === 'none' || i === 5) break;
    if (RETRY === 'backoff') sleep((200 * 2 ** i) * (0.5 + Math.random()) / 1000);
  }
  gaveUp.add(1);
}
export function handleSummary(data) {
  const v = (k) => (data.metrics[k] ? data.metrics[k].values.count : 0), d = data.metrics.create_ms.values, out = { retry: RETRY, rate: RATE };
  for (const p of ['before', 'during', 'after']) out[p] = { attempts: v(`attempts{phase:${p}}`), created: v(`created{phase:${p}}`), gave_up: v(`gave_up{phase:${p}}`) };
  out.create_p50_ms = +d['p(50)'].toFixed(1); out.create_p99_ms = +d['p(99)'].toFixed(1);
  return { [RESULT]: JSON.stringify(out, null, 1), stdout: `written to ${RESULT}\n` };
}
