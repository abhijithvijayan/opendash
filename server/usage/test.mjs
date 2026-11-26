// node --test server/usage/test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker, { check, isoWeek, leadingZeroBits } from './src/index.js';

const NOW = Date.UTC(2026, 10, 25, 9);
const payload = (o = {}) =>
  JSON.stringify({ v: 2, week: '2026-W48', new: true, app: '0.2.0', build: 1612, gen: '1', model: 'S1 Pro', moveos: '4.6.14', stock: '4.6.14', android: '10', ...o });

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

test('the Android version is kept, and an app too old to send it still counts', async () => {
  const ping = payload();
  assert.equal((await check(JSON.stringify({ ping, n: solve(ping, 22) }), NOW)).android, '10');
  const old = payload({ android: undefined });
  assert.equal((await check(JSON.stringify({ ping: old, n: solve(old, 22) }), NOW)).android, '');
  const odd = payload({ android: '10; DROP TABLE' });
  assert.equal(await check(JSON.stringify({ ping: odd, n: solve(odd, 22) }), NOW), null);
});

test('a ping without the stock service version is refused: it came from a phone, not a scooter', async () => {
  const phone = payload({ gen: '', model: '', moveos: '', stock: '', android: '16' });
  assert.equal(await check(JSON.stringify({ ping: phone, n: solve(phone, 22) }), NOW), null);
});

test('a stored ping says which address it came in on', async () => {
  const ping = payload();
  const body = JSON.stringify({ ping, n: solve(ping, 22) });
  const bound = [];
  const DB = { prepare: () => ({ bind: (...args) => ({ run: async () => bound.push(args) }) }) };
  const now = Date.now;
  Date.now = () => NOW;
  try {
    const res = await worker.fetch(new Request('https://w/v1/ping', { method: 'POST', body }), { DB, VIA: 'v2' });
    assert.equal(res.status, 204);
  } finally {
    Date.now = now;
  }
  assert.equal(bound.length, 1);
  assert.equal(bound[0].at(-1), 'v2');
});

test('the head unit hardware is kept, and an app too old to send it still counts', async () => {
  const hw = {
    screen: '1280x768', density: '236', density_default: '480', maker: 'QUALCOMM', device: 'Ola HU',
    board: 'msmnile', soc: 'qcom', abi: 'arm64-v8a', ram_gb: '4', fw: 'QKQ1.200830.002 release-keys', patch: '2021-10-05',
  };
  const ping = payload(hw);
  const row = await check(JSON.stringify({ ping, n: solve(ping, 22) }), NOW);
  for (const [k, v] of Object.entries(hw)) assert.equal(row[k], v, k);
  const old = payload();
  const oldRow = await check(JSON.stringify({ ping: old, n: solve(old, 22) }), NOW);
  assert.equal(oldRow.screen, '');
  assert.equal(oldRow.fw, '');
  const odd = payload({ ...hw, fw: 'a/b' });
  assert.equal(await check(JSON.stringify({ ping: odd, n: solve(odd, 22) }), NOW), null, 'the app cleans these; one that does not is not this app');
});

test('a firmware build name may be up to 80 characters; the other fields 40', async () => {
  const fw = 'sdk_phone64_arm64-userdebug 10 QSR1.211112.011 7955567 test-keys';
  const ok = payload({ fw });
  assert.equal((await check(JSON.stringify({ ping: ok, n: solve(ok, 22) }), NOW)).fw, fw);
  const long = payload({ fw: 'x'.repeat(81) });
  assert.equal(await check(JSON.stringify({ ping: long, n: solve(long, 22) }), NOW), null);
  const board = payload({ board: 'x'.repeat(41) });
  assert.equal(await check(JSON.stringify({ ping: board, n: solve(board, 22) }), NOW), null);
});
