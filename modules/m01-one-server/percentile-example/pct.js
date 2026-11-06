import { Trend } from 'k6/metrics';
const t = new Trend('example_ms');
export const options = { iterations: 1, summaryTrendStats: ['p(50)', 'p(90)', 'p(99)', 'avg', 'max'] };
export default function () { for (const v of [5, 5, 6, 6, 6, 7, 7, 8, 9, 120]) t.add(v); }
