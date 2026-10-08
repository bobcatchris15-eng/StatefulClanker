import { test } from 'node:test';
import assert from 'node:assert/strict';
import { visibleWidth } from '@earendil-works/pi-tui';
import { BLINK_PERIOD_MS, blinkOffset, blinkOn, LampBank, MAX_DT_MS, RackClock } from '../../ui/lamp-bank.ts';
import { renderRack, type RackWorker } from '../../ui/worker-rack.ts';

const W: RackWorker = { id: 'W01', status: 'RUNNING', model: 'm1', task_id: 't-0001' };

test('first sight of a worker seeds a lamp, repeat syncs are idempotent', () => {
  const b = new LampBank(8);
  b.sync([W], 1000);
  assert.deepEqual(b.bank('W01'), [{ status: 'RUNNING', at: 1000 }]);
  b.sync([W], 1100);
  b.sync([W], 1200);
  assert.equal(b.bank('W01').length, 1, 'no new lamp without a status change');
});

test('each status change lights exactly one new lamp', () => {
  const b = new LampBank(8);
  b.sync([W], 0);
  b.sync([{ id: 'W01', status: 'WAITING' }], 10);
  b.sync([{ id: 'W01', status: 'BLOCKED' }], 20);
  assert.deepEqual(b.bank('W01').map((l) => l.status), ['RUNNING', 'WAITING', 'BLOCKED']);
  assert.deepEqual(b.bank('W01').map((l) => l.at), [0, 10, 20]);
});

test('a full bank drops the oldest lamp', () => {
  const b = new LampBank(3);
  for (let i = 0; i < 6; i++) b.sync([{ id: 'W01', status: `S${i}` }], i);
  assert.deepEqual(b.bank('W01').map((l) => l.status), ['S3', 'S4', 'S5']);
  assert.equal(b.bank('W01').length, 3);
});

test('banks are per worker and do not leak across ids', () => {
  const b = new LampBank(8);
  b.sync([W, { id: 'W02', status: 'IDLE' }], 0);
  assert.deepEqual(b.bank('W02').map((l) => l.status), ['IDLE']);
  assert.equal(b.bank('W99').length, 0);
});

test('prune drops banks of workers gone for longer than the ttl', () => {
  const b = new LampBank(8);
  b.sync([W, { id: 'W02', status: 'RUNNING' }], 0);
  b.prune(['W01'], 60_000, 30_000);          // W02 still inside the ttl
  assert.equal(b.bank('W02').length, 1);
  b.prune(['W01'], 60_000, 90_000);          // W02 now stale
  assert.equal(b.bank('W02').length, 0);
  assert.equal(b.bank('W01').length, 1, 'live workers keep their lamps');
});

test('clock advances by real deltas and wraps at one full cycle', () => {
  const c = new RackClock(BLINK_PERIOD_MS);
  assert.equal(c.advance(0), false, 'first tick only establishes a baseline');
  c.advance(100);
  assert.equal(c.phase, 0.25);
  c.advance(300);
  assert.equal(c.phase, 0.75);
  c.advance(800);                              // dt clamped, but still past one cycle
  assert.equal(c.phase, 0, 'wrapped');
});

test('a suspended process does not make the lamps jump', () => {
  const c = new RackClock(BLINK_PERIOD_MS);
  c.advance(0);
  c.advance(10_000);                          // laptop lid closed for ten seconds
  assert.ok(c.phase <= MAX_DT_MS / BLINK_PERIOD_MS, `phase jumped to ${c.phase}`);
});

test('clock never goes backwards on a non-monotonic tick', () => {
  const c = new RackClock(BLINK_PERIOD_MS);
  c.advance(1000);
  c.advance(200);
  assert.equal(c.phase, 0);
});

test('blink offsets differ per worker so the rack does not strobe in unison', () => {
  const offsets = ['W01', 'W02', 'W03', 'W04', 'W05'].map(blinkOffset);
  assert.ok(offsets.every((o) => o >= 0 && o < 1));
  assert.equal(new Set(offsets).size, offsets.length);
  // At any given phase at least two of five workers sit on opposite halves of the cycle.
  for (const phase of [0, 0.13, 0.37, 0.62, 0.88]) {
    const ons = ['W01', 'W02', 'W03', 'W04', 'W05'].map((id) => blinkOn(id, phase));
    assert.ok(ons.includes(true) && ons.includes(false), `all lamps in phase at ${phase}`);
  }
});

test('blinkOn is a pure function of id and phase', () => {
  assert.equal(blinkOn('W01', 0.25), blinkOn('W01', 0.25));
  assert.equal(blinkOffset('W01'), blinkOffset('W01'));
});

test('a real bank feeds the renderer: lit lamps carry the state colour, sockets are dark', () => {
  const b = new LampBank(8);
  const idle: RackWorker = { id: 'W01', status: 'IDLE', model: 'm1', task_id: 't-0001' };
  b.sync([{ id: 'W01', status: 'RUNNING' }], 0);
  b.sync([{ id: 'W01', status: 'COMPLETE' }], 10);
  const row = renderRack([idle], 96, { maxLamps: 6, phase: 0, lamps: (id) => b.bank(id) })[1]!;
  const cell = (row.match(/[█▓▒░·]+(?= W01)/) ?? [''])[0]!;
  assert.equal(cell.length, 6, 'sockets are drawn, so the cell never changes width');
  assert.equal(cell.slice(0, 4), '\u00b7\u00b7\u00b7\u00b7', 'four dark sockets');
  assert.match(cell.slice(4), /^[\u2593][\u2588]$/, 'one step back, then the newest lamp at the right');
  assert.ok(visibleWidth(row) <= 96);
});