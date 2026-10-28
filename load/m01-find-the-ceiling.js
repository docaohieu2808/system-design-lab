// Module 1: step the request rate up and watch where one server stops keeping up.
// Each step holds a fixed arrival rate for 20 s; results are tagged with the step.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE || 'http://app:8080';
const STEPS = (__ENV.STEPS || '250,500,1000,1500,2000,3000,4000,6000').split(',').map(Number);
const HOLD = 20; // seconds per step
const GAP = 5;   // quiet seconds between steps

export const options = {
  maxRedirects: 0, // measure our redirect, never follow it to the long URL
  discardResponseBodies: true,
  scenarios: Object.fromEntries(STEPS.map((rate, i) => [`rps_${rate}`, {
    executor: 'constant-arrival-rate',
    rate, timeUnit: '1s',
    duration: `${HOLD}s`,
    startTime: `${i * (HOLD + GAP)}s`,
    preAllocatedVUs: Math.min(rate, 500),
    maxVUs: 3000,
    tags: { step: String(rate) },
  }])),
};

export default function () {
  const res = http.get(`${BASE}/${b62(1 + Math.floor(Math.random() * 100000))}`, { timeout: '3s', tags: { name: 'GET /{code}' } });
  check(res, { 'redirected': (r) => r.status === 302 });
}

const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
function b62(n) {
  let s = '';
  while (n > 0) { s = A[n % 62] + s; n = Math.floor(n / 62); }
  return s;
}
