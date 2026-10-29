// Module 11: step the offered load on the preview page and count goodput: answers that are correct (200) AND come
// back within GOOD_MS. Fast refusals (429) are counted separately; they are cheap and honest.
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://app:8080', STEPS = (__ENV.STEPS || '300,600,900,1200,1500').split(',').map(Number);
const HOLD = 15, GAP = 5, GOOD_MS = Number(__ENV.GOOD_MS || 500), RESULT = __ENV.RESULT || 'results/run.json';
const good = new Counter('good'), slow = new Counter('slow'), refused = new Counter('refused'), failed = new Counter('failed');
const scenarios = {}, thresholds = {};
STEPS.forEach((rate, i) => {
  scenarios[`r${rate}`] = { executor: 'constant-arrival-rate', rate, timeUnit: '1s', duration: `${HOLD}s`, startTime: `${i * (HOLD + GAP)}s`,
    preAllocatedVUs: Math.min(rate, 500), maxVUs: 3000, tags: { step: String(rate) } };
  for (const c of ['good', 'slow', 'refused', 'failed']) thresholds[`${c}{step:${rate}}`] = ['count>=0'];
});
export const options = { discardResponseBodies: true, scenarios, thresholds };
const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function b62(n) { let s = ''; while (n > 0) { s = A[n % 62] + s; n = Math.floor(n / 62); } return s; }
export default function () {
  const r = http.get(`${BASE}/page/${b62(1 + Math.floor(Math.random() * 100000))}`, { timeout: '5s' });
  if (r.status === 200 && r.timings.duration <= GOOD_MS) good.add(1);
  else if (r.status === 200) slow.add(1);
  else if (r.status === 429) refused.add(1);
  else failed.add(1);
}
export function handleSummary(data) {
  const v = (k) => (data.metrics[k] ? data.metrics[k].values.count : 0);
  const steps = STEPS.map((rate) => ({ offered: rate, goodput: v(`good{step:${rate}}`) / HOLD, slow_per_s: v(`slow{step:${rate}}`) / HOLD,
    refused_per_s: v(`refused{step:${rate}}`) / HOLD, failed_per_s: v(`failed{step:${rate}}`) / HOLD }));
  return { [RESULT]: JSON.stringify({ good_ms: GOOD_MS, steps }, null, 1), stdout: `written to ${RESULT}\n` };
}
