import { test } from 'node:test';
import assert from 'node:assert/strict';
import { visibleWidth } from '@earendil-works/pi-tui';
import {
  activityOf, DEFAULT_LAMPS, LampField, lampOn, lampSpec, MAX_DT_MS, MAX_PERIOD_MS, MIN_PERIOD_MS, RackClock,
} from '../../ui/lamp-bank.ts';
import { renderRack, type RackWorker } from '../../ui/worker-rack.ts';

const W: RackWorker = { id: 'W01', status: 'RUNNING', model: 'm1', task_id: 't-0001' };
const IDS = ['W01', 'W02', 'W03', 'W04', 'W05', 'W06'];

/* ------------------------------------------------------------------ *
 * Lamp field (liveness + colour source)
 * ------------------------------------------------------------------ */

test('field tracks liveness and current status, idempotently', () => {
  const f = new LampField(DEFAULT_LAMPS);
  f.sync([W], 1000);
  assert.equal(f.statusOf('W01'), 'RUNNING');
  f.sync([W], 1100);
  f.sync([W], 1200);
  assert.equal(f.statusOf('W01'), 'RUNNING', 'repeat syncs do not disturb the field');
  f.sync([{ id: 'W01', status: 'WAITING' }], 1300);
  assert.equal(f.statusOf('W01'), 'WAITING');
  assert.equal(f.statusOf('W99'), undefined);
});

test('prune drops workers gone for longer than the ttl, keeps the live ones', () => {
  const f = new LampField(DEFAULT_LAMPS);
  f.sync([W, { id: 'W02', status: 'RUNNING' }], 0);
  f.prune(['W01'], 60_000, 30_000);
  assert.equal(f.statusOf('W02'), 'RUNNING', 'still inside the ttl');
  f.prune(['W01'], 60_000, 90_000);
  assert.equal(f.statusOf('W02'), undefined, 'now stale');
  assert.equal(f.statusOf('W01'), 'RUNNING', 'live workers keep their lamps');
});

/* ------------------------------------------------------------------ *
 * Clock
 * ------------------------------------------------------------------ */

test('clock accumulates clamped real deltas', () => {
  const c = new RackClock();
  assert.equal(c.advance(0), false, 'first tick only establishes a baseline');
  assert.equal(c.advance(100), true);
  assert.equal(c.elapsedMs, 100);
  c.advance(300);
  assert.equal(c.elapsedMs, 300);
});

test('a suspended process does not make the lamps jump', () => {
  const c = new RackClock();
  c.advance(0);
  c.advance(10_000);                       // laptop lid closed for ten seconds
  assert.equal(c.elapsedMs, MAX_DT_MS);
});

test('clock never goes backwards on a non-monotonic tick', () => {
  const c = new RackClock();
  c.advance(1000);
  c.advance(200);
  assert.equal(c.elapsedMs, 0);
});

/* ------------------------------------------------------------------ *
 * Per-lamp oscillators: the whole point
 * ------------------------------------------------------------------ */

test('every lamp gets its own period, offset, duty and segment count', () => {
  const specs = IDS.flatMap((id) => [0, 1, 2, 3, 4, 5].map((i) => lampSpec(id, i)));
  assert.ok(specs.every((s) => s.periodMs >= MIN_PERIOD_MS && s.periodMs <= MAX_PERIOD_MS));
  assert.ok(specs.every((s) => s.offsetMs >= 0 && s.offsetMs < s.periodMs));
  assert.ok(specs.every((s) => s.duty > 0 && s.duty < 1));
  assert.ok(specs.every((s) => s.segments >= 1 && s.segments <= 3));
  // 36 lamps, 36 different periods: nothing is wired to a shared oscillator.
  assert.equal(new Set(specs.map((s) => s.periodMs)).size, specs.length);
});

test('lamp specs are stable across calls (no per-frame reshuffle)', () => {
  assert.deepEqual(lampSpec('W01', 3), lampSpec('W01', 3));
  assert.notDeepEqual(lampSpec('W01', 3), lampSpec('W02', 3));
});

test('lampOn is a pure function of id, index and animation time', () => {
  assert.equal(lampOn('W01', 2, 1234), lampOn('W01', 2, 1234));
});

test('no two lamps in a rack are ever in lockstep', () => {
  // Over a long run, no pair may agree on their on/off state more often than chance.
  for (const [a, b] of [[0, 1], [0, 3], [2, 5], [1, 4]]) {
    let agree = 0;
    const samples = 4000;
    for (let k = 0; k < samples; k++) {
      const t = k * 7;
      if (lampOn('W01', a, t) === lampOn('W01', b, t)) agree++;
    }
    const ratio = agree / samples;
    assert.ok(ratio > 0.25 && ratio < 0.75, `lamps ${a}/${b} agree ${(ratio * 100).toFixed(0)}% of the time`);
  }
});

test('a busy bank is rarely all-on or all-off (real panels do go briefly dark)', () => {
  let allOff = 0;
  let allOn = 0;
  const samples = 3000;
  for (let k = 0; k < samples; k++) {
    const t = k * 11;
    const lit = Array.from({ length: DEFAULT_LAMPS }, (_, i) => lampOn('W01', i, t, 1));
    const n = lit.filter(Boolean).length;
    if (n === 0) allOff++;
    if (n === DEFAULT_LAMPS) allOn++;
  }
  assert.ok(allOff / samples < 0.06, `bank goes dark too often: ${((allOff / samples) * 100).toFixed(1)}%`);
  assert.ok(allOn / samples < 0.06, `bank floods too often: ${((allOn / samples) * 100).toFixed(1)}%`);
});

test('a RUNNING worker blazes; a COMPLETE one is nearly dark', () => {
  let busy = 0;
  let done = 0;
  const samples = 3000;
  for (let k = 0; k < samples; k++) {
    const t = k * 9;
    for (let i = 0; i < DEFAULT_LAMPS; i++) {
      if (lampOn('W01', i, t, activityOf('RUNNING'))) busy++;
      if (lampOn('W01', i, t, activityOf('COMPLETE'))) done++;
    }
  }
  assert.ok(busy / done > 3, `RUNNING ${busy} vs COMPLETE ${done}: activity scaling is too weak`);
  assert.ok(busy / (samples * DEFAULT_LAMPS) > 0.4, 'a running worker should blaze');
});

/* ------------------------------------------------------------------ *
 * Renderer
 * ------------------------------------------------------------------ */

test('a real bank feeds the renderer: six drawn sockets, colour from the state token', () => {
  const f = new LampField(DEFAULT_LAMPS);
  f.sync([W], 0);
  const lines = renderRack([W], 96, { maxLamps: DEFAULT_LAMPS, nowMs: 137, lit: (id, i) => lampOn(id, i, 137, activityOf('RUNNING')) });
  const row = lines[1]!;
  const cell = (row.match(/[█▓▒·]+(?= W01)/) ?? [''])[0]!;
  assert.equal(cell.length, DEFAULT_LAMPS, 'every socket is drawn, so the cell width is constant');
  assert.ok(visibleWidth(row) <= 96);
  assert.equal(f.statusOf('W01'), 'RUNNING');
});

test('lamp sockets never change the row width, whatever the animation time', () => {
  const widths = new Set<string>();
  for (let k = 0; k < 400; k++) {
    const line = renderRack([W, { ...W, id: 'W02', status: 'COMPLETE' }], 110, { nowMs: k * 13 })[1]!;
    widths.add((line.match(/[█▓▒·]+/)?.[0] ?? '').length + ':' + visibleWidth(line));
  }
  assert.equal(widths.size, 1, `rows changed width over time: ${[...widths].join(', ')}`);
});

test('the rack is alive: consecutive frames differ for every worker', () => {
  const workers = IDS.map((id) => ({ ...W, id }));
  let changed = 0;
  for (const id of IDS) {
    let diff = 0;
    for (let k = 0; k < 60; k++) {
      const a = renderRack([{ ...W, id }], 96, { nowMs: k * 100 })[1]!;
      const b = renderRack([{ ...W, id }], 96, { nowMs: k * 100 + 100 })[1]!;
      if (a !== b) diff++;
    }
    if (diff > 30) changed++;
  }
  assert.equal(changed, IDS.length, 'some workers never move');
});
