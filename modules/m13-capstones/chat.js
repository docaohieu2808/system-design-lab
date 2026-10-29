// Capstone 13.4: CONNS listeners spread over 20 rooms stay connected for 40 s; a sender posts one message per room
// every second from 5 s to 35 s. Delivery time = when the listener got it minus when the server stamped it.
import ws from 'k6/ws';
import http from 'k6/http';
import { Trend, Counter } from 'k6/metrics';
import { sleep } from 'k6';

const BASE = __ENV.BASE || 'http://app:8080', WS = BASE.replace('http', 'ws'), CONNS = Number(__ENV.CONNS || 500);
const RESULT = __ENV.RESULT || 'results/chat.json';
const delivery = new Trend('delivery_ms', true), got = new Counter('received'), sent = new Counter('sent_to');
export const options = {
  summaryTrendStats: ['p(50)', 'p(99)', 'max'],
  scenarios: {
    listeners: { executor: 'per-vu-iterations', vus: CONNS, iterations: 1, maxDuration: '60s', exec: 'listen' },
    sender: { executor: 'constant-arrival-rate', rate: 20, timeUnit: '1s', duration: '30s', startTime: '5s', preAllocatedVUs: 20, exec: 'send' },
  },
};
export function listen() {
  ws.connect(`${WS}/ws?room=r${__VU % 20}`, {}, (socket) => {
    socket.on('message', (m) => { delivery.add(Date.now() - JSON.parse(m).sent_ms); got.add(1); });
    socket.setTimeout(() => socket.close(), 40000);
  });
}
let k = 0;
export function send() {
  const r = http.post(`${BASE}/api/rooms/r${k++ % 20}/send`, 'hello');
  sent.add(Number(r.body) || 0);
}
export function handleSummary(data) {
  const m = data.metrics, d = m.delivery_ms ? m.delivery_ms.values : {};
  return { [RESULT]: JSON.stringify({ conns: CONNS, sent_to: m.sent_to ? m.sent_to.values.count : 0, received: m.received ? m.received.values.count : 0,
    delivery_p50_ms: d['p(50)'], delivery_p99_ms: d['p(99)'], delivery_max_ms: d.max }, null, 1), stdout: `written to ${RESULT}\n` };
}
