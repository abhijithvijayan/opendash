// node --test server/usage/test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { check, isoWeek, leadingZeroBits } from './src/index.js';

const NOW = Date.UTC(2026, 10, 25, 9);
const payload = (o = {}) =>
  JSON.stringify({ v: 2, week: '2026-W48', new: true, app: '0.2.0', build: 1612, gen: '1', model: 'S1 Pro', moveos: '4.6.14', stock: '4.6.14', ...o });

function solve(ping, bits) {
  for (let n = 0; ; n++) {
    if (leadingZeroBits(createHash('sha256').update(`${ping}:${n}`).digest()) >= bits) return n;
  }
}

test('iso weeks', () => {
  assert.equal(isoWeek(NOW), '2026-W48');
  assert.equal(isoWeek(Date.UTC(2027, 0, 1)), '2026-W53');
  assert.equal(isoWeek(Date.UTC(2024, 11, 30)), '2025-W01');
});

test('a proved ping for this week is taken', async () => {
  const ping = payload();
  const row = await check(JSON.stringify({ ping, n: solve(ping, 22) }), NOW);
  assert.equal(row.week, '2026-W48');
  assert.equal(row.proof.length, 64);
});

test('too little work, another week, an old version or a changed ping is refused', async () => {
  const ping = payload();
  const n = solve(ping, 22);
  let weak = 0;
  while (leadingZeroBits(createHash('sha256').update(`${ping}:${weak}`).digest()) >= 22) weak++;
  assert.equal(await check(JSON.stringify({ ping, n: weak }), NOW), null);
  assert.equal(await check(JSON.stringify({ ping: payload({ new: false }), n }), NOW), null);
  const future = payload({ week: '2026-W52' });
  assert.equal(await check(JSON.stringify({ ping: future, n: solve(future, 22) }), NOW), null);
  const v1 = payload({ v: 1 });
  assert.equal(await check(JSON.stringify({ ping: v1, n: solve(v1, 22) }), NOW), null);
});
