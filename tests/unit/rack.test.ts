import { test } from 'node:test';
import assert from 'node:assert/strict';
import { visibleWidth } from '@earendil-works/pi-tui';
import { DEFAULT_MAX_ROWS, MIN_BOX_WIDTH, renderRack, SYMBOLS, type RackWorker } from '../../ui/worker-rack.ts';

const ws: RackWorker[] = [
  { id: 'W03', status: 'RUNNING', model: 'glm-flash', current_action: 'editing x.ts', task_id: 't-0003' },
  { id: 'W04', status: 'BLOCKED', model: 'm2', task_id: 't-0004' },
  { id: 'W05', status: 'COMPLETE', model: 'm3', task_id: 't-0005' },
  { id: 'W06', status: 'FAILED', model: 'm4', task_id: 't-0006' },
  { id: 'W07', status: 'IDLE', model: 'm5', task_id: 't-0007' },
  { id: 'W08', status: 'WAITING', model: 'm6', task_id: 't-0008' },
];

const eight: RackWorker[] = Array.from({ length: 8 }, (_, i) => ({
  id: `W0${i + 1}`,
  display_name: ['Rivet', 'Anvil', 'Brace', 'Cog', 'Die', 'Ember', 'Flint', 'Girder'][i],
  status: ['RUNNING', 'RUNNING', 'WAITING', 'BLOCKED', 'STARTING', 'IDLE', 'COMPLETE', 'FAILED'][i]!,
  model: ['glm-flash', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8'][i]!,
  task_id: `t-000${i + 1}`,
  task_title: i % 2 ? undefined : `Job number ${i + 1}: fix the widget`,
  current_action: i % 3 ? '' : `editing ui/worker-rack.ts with a very long action string ${i}`,
}));

/** Every line must fit the width, measured in visible columns, ANSI included. */
const fits = (l: string[], w: number): boolean => l.every((x) => visibleWidth(x) <= w);

test('boxed panel: header carries per-state counts and job totals', () => {
  const l = renderRack(ws, 110);
  assert.ok(l[0]!.startsWith('┌') && l[0]!.includes('SUPERVISOR'));
  assert.match(l[0]!, /RUN 1/);
  assert.match(l[0]!, /WAIT 1/);
  assert.match(l[0]!, /FAIL 1/);
  assert.match(l[0]!, /jobs 3\/6/); // W03 + W08 + W04 active, 6 distinct jobs
  assert.ok(l.at(-1)!.startsWith('└'));
  assert.ok(fits(l, 110));
  assert.equal(l.length, ws.length + 2);
});

test('active workers sort above idle/finished, id order within a group', () => {
  const ids = renderRack(ws, 110).slice(1, -1).map((l) => l.match(/W\d\d/)![0]);
  assert.deepEqual(ids, ['W03', 'W04', 'W08', 'W07', 'W05', 'W06']);
});

test('zero workers renders an idle panel, never an empty array', () => {
  const l = renderRack([], 80);
  assert.ok(l.length > 0);
  assert.match(l.join('\n'), /idle/);
  assert.ok(fits(l, 80));
});

test('narrow widths drop the box and strip', () => {
  const width = MIN_BOX_WIDTH - 1;
  const l = renderRack(ws, width);
  assert.ok(l.every((x) => !x.startsWith('│')));
  assert.equal(l.length, ws.length);
  // Narrow rows keep a lamp bank, just a shallower one.
  assert.match(l[0]!, /^W03 \S+ [█▓▒░·]+ RUN t-0/);
  assert.ok(fits(l, width));
});

test('lamp banks never exceed the requested depth, at any width', () => {
  for (const width of [30, 40, 60, 80, 120, 200]) {
    const l = renderRack(ws, width, { maxLamps: 4 });
    const banks = l.filter((x) => x.startsWith('│') && x.includes('W')).map((x) => (x.match(/[█▓▒░·]+(?= W\d)/) ?? [''])[0]!.length);
    for (const n of banks) assert.ok(n <= 4, `bank of ${n} at width ${width}`);
    assert.ok(banks.length === ws.length);
  }
});

test('every row keeps a fixed-width bank cell so the columns never jitter', () => {
  const cells = renderRack(ws, 110, { maxLamps: 6 }).slice(1, -1).map((l) => (l.match(/[█▓▒░·]+(?= W\d)/) ?? [''])[0]!.length);
  assert.equal(new Set(cells).size, 1);
  assert.ok(cells[0]! > 1);
});

test('lamp bank is deterministic: same inputs, same bytes', () => {
  const opts = { maxLamps: 8, phase: 0.25 } as const;
  assert.deepEqual(renderRack(ws, 96, opts), renderRack(ws, 96, opts));
});

test('phase 0 and phase 0.5 differ for at least one blinking worker', () => {
  const on = renderRack(ws, 96, { maxLamps: 8, phase: 0 }).join('\n');
  const off = renderRack(ws, 96, { maxLamps: 8, phase: 0.5 }).join('\n');
  assert.notEqual(on, off);
});

test('only active workers blink; idle/finished lamps hold steady', () => {
  const active = new Set(['RUNNING', 'STARTING', 'WAITING', 'BLOCKED']);
  const ids: string[] = [];
  for (const w of ws) {
    const on = renderRack([w], 96, { maxLamps: 6, phase: 0 }).join('');
    const off = renderRack([w], 96, { maxLamps: 6, phase: 0.5 }).join('');
    const bankOn = (on.match(/[█▓▒░·]+(?= W\d)/) ?? [''])[0]!;
    const bankOff = (off.match(/[█▓▒░·]+(?= W\d)/) ?? [''])[0]!;
    if (active.has(w.status)) ids.push(`${w.id}:${bankOn !== bankOff ? 'blinks' : 'STATIC'}`);
    else assert.equal(bankOn, bankOff, `${w.id} should hold a steady lamp`);
  }
  assert.ok(ids.length === 3 && ids.every((x) => x.endsWith(':blinks')), ids.join(' '));
});

test('golden render: 3 workers at 80 cols, phase pinned', () => {
  const golden = [
    '\u250c SUPERVISOR  \u00b7 RUN 1 \u00b7  DONE 1 \u00b7  IDLE 1 jobs 1/2 \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510',
    '\u2502 \u00b7 \u00b7\u00b7\u00b7\u00b7\u00b7\u00b7 W01 Rivet  Ship the lamp bank  m1                      edit ui/lamp \u2502',
    '\u2502 \u25cb \u00b7\u00b7\u00b7\u00b7\u00b7\u2588 W03                            m3                                   \u2502',
    '\u2502 \u2713 \u00b7\u00b7\u00b7\u00b7\u00b7\u2588 W02 Anvil  Review              m2                                   \u2502',
    '\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500┘',
  ];
  const rows: RackWorker[] = [
    { id: 'W01', display_name: 'Rivet', status: 'RUNNING', model: 'm1', task_id: 't-0001', task_title: 'Ship the lamp bank', current_action: 'edit ui/lamp' },
    { id: 'W02', display_name: 'Anvil', status: 'COMPLETE', model: 'm2', task_id: 't-0002', task_title: 'Review' },
    { id: 'W03', status: 'IDLE', model: 'm3' },
  ];
  assert.deepEqual(renderRack(rows, 80, { maxLamps: 6, phase: 0 }), golden);
});

test('long worker names and task titles never widen a line', () => {
  const l = renderRack([{ ...eight[0]!, display_name: 'A-very-long-worker-name-that-goes-on', task_title: 'Extremely long task title that will not fit anywhere at all' }], 60);
  assert.ok(fits(l, 60));
  assert.ok(l.join('\n').includes('…'));
});

test('no line exceeds width at 60/80/120 with 0, 1 and 8 workers', () => {
  for (const width of [60, 80, 120]) {
    for (const set of [[], ws.slice(0, 1), eight]) {
      const plain = renderRack(set, width);
      assert.ok(plain.length > 0, `no lines at ${width}`);
      assert.ok(fits(plain, width), `plain overflow at ${width}/${set.length}`);
      const themed = renderRack(set, width, { theme: { fg: (_t: string, s: string) => `\u001b[35m${s}\u001b[0m` } });
      assert.ok(fits(themed, width), `themed overflow at ${width}/${set.length}`);
      assert.equal(themed.length, plain.length);
    }
  }
});

test('emoji and CJK in names measure by column, not by string length', () => {
  const l = renderRack([{ id: 'W01', display_name: 'ナージ\u{1F680}ナージ', status: 'RUNNING', model: 'm', current_action: 'go\u{1F680}\u{1F680}' }], 60);
  assert.ok(fits(l, 60));
});

test('many workers are capped with an overflow line', () => {
  const l = renderRack(eight, 120, { maxRows: 3 });
  assert.equal(l.length, 3 + 1 + 2);
  assert.match(l[l.length - 2]!, /\+5 more/);
  assert.equal(DEFAULT_MAX_ROWS, 8);
});

test('degenerate widths do not throw', () => {
  for (const width of [0, 1, 5, MIN_BOX_WIDTH - 1, MIN_BOX_WIDTH]) {
    assert.ok(fits(renderRack(eight, width), width));
  }
});

test('every documented status has a distinct glyph', () => {
  const syms = ['RUNNING', 'WAITING', 'BLOCKED', 'FAILED', 'COMPLETE', 'IDLE', 'LOST', 'STARTING'].map((s) => SYMBOLS[s]!.sym);
  assert.equal(new Set(syms).size, syms.length);
});

test('name and task title both visible on a row', () => {
  const l = renderRack([{ id: 'W01', display_name: 'Rivet', status: 'RUNNING', model: 'glm', task_id: 't-0007', task_title: 'Fix the sidepanel' }], 100);
  const row = l[1]!;
  assert.match(row, /Rivet/);
  assert.match(row, /Fix the sidepanel/);
});

test('unknown status degrades without breaking width', () => {
  const l = renderRack([{ id: 'W01', status: 'WEIRD_NEW_STATE', model: 'm' }], 40);
  assert.match(l[1]!, /WEIRD_NEW/);
  assert.ok(fits(l, 40));
});