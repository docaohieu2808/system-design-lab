// Module 6: create a link, then open it straight away, as the same user. With reads going to a replica that is
// behind, the fresh link may not be there yet: the redirect answers 404. Counts how often that happens.
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://app:8080';
const RATE = Number(__ENV.RATE || 50);
const DURATION = Number(__ENV.DURATION || 30);
const RESULT = __ENV.RESULT || 'results/run.json';
const found = new Counter('read_found'), missing = new Counter('read_missing'), failed = new Counter('failed');

export const options = {
  maxRedirects: 0,
  scenarios: { load: { executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: `${DURATION}s`,
    preAllocatedVUs: 100, maxVUs: 500 } },
};

export default function () {
  const c = http.post(`${BASE}/api/links`, JSON.stringify({ url: `https://example.com/new/${__VU}-${__ITER}` }),
    { headers: { 'Content-Type': 'application/json' }, timeout: '5s' });
  if (c.status !== 201) { failed.add(1); return; }
  const r = http.get(`${BASE}/${c.json('code')}`, { timeout: '5s', tags: { name: 'GET /{code}' } });
  if (r.status === 302) found.add(1); else if (r.status === 404) missing.add(1); else failed.add(1);
}

export function handleSummary(data) {
  const v = (k) => (data.metrics[k] ? data.metrics[k].values.count : 0);
  const f = v('read_found'), m = v('read_missing');
  return { [RESULT]: JSON.stringify({ rate: RATE, found: f, missing: m, failed: v('failed'),
    missing_pct: +(100 * m / Math.max(1, f + m)).toFixed(2) }, null, 1), stdout: `written to ${RESULT}\n` };
}
