import { test } from 'node:test';
import assert from 'node:assert/strict';
import { visibleWidth } from '@earendil-works/pi-tui';
import {
  allocateColumnWidths,
  clipToWidth,
  DEFAULT_MAX_ROWS,
  externalPoolIds,
  formatElapsed,
  MIN_COLUMN_WIDTH,
  POOL_GLYPHS,
  poolGlyph,
  type PoolJobView,
  renderPoolPane,
  renderSplitPanes,
} from '../../ui/pool-pane.ts';

/** Every line must fit the width, measured in visible columns, ANSI included. */
const fits = (lines: string[], w: number): boolean => lines.every((l) => visibleWidth(l) <= w);

const job = (over: Partial<PoolJobView> = {}): PoolJobView => ({
  id: 'j1',
  title: 'Fix widget',
  status: 'running',
  startedAtMs: 1_000,
  changedFiles: 2,
  ...over,
});

test('glyph map covers every status with distinct single-width symbols', () => {
  const statuses = ['queued', 'starting', 'running', 'waiting_input', 'succeeded', 'failed', 'cancelled', 'unknown'] as const;
  const seen = new Set<string>();
  for (const s of statuses) {
    const g = POOL_GLYPHS[s];
    assert.ok(g, `missing glyph for ${s}`);
    assert.equal(visibleWidth(g), 1, `${s} glyph must be single width`);
    assert.ok(!seen.has(g), `glyph for ${s} must be distinct`);
    seen.add(g);
  }
  // Fallback behaviour for unrecognised lifecycle strings.
  assert.equal(poolGlyph('weird'), POOL_GLYPHS.unknown);
  assert.equal(poolGlyph('running'), POOL_GLYPHS.running);
});

test('externalPoolIds is the stable non-native order', () => {
  assert.deepEqual(externalPoolIds(), ['opencode', 'agy', 'jules']);
});

test('formatElapsed is compact and single-unit', () => {
  assert.equal(formatElapsed(0), '0s');
  assert.equal(formatElapsed(45_000), '45s');
  assert.equal(formatElapsed(12 * 60_000), '12m');
  assert.equal(formatElapsed(3 * 3_600_000), '3h');
  assert.equal(formatElapsed(2 * 86_400_000), '2d');
  assert.equal(formatElapsed(-5), '0s'); // clamps, deterministic
});

test('single pane renders a box with header, one row per job, elapsed, title, files', () => {
  const jobs = [
    job({ id: 'a', title: 'alpha', status: 'running', startedAtMs: 1_000, changedFiles: 3 }),
    job({ id: 'b', title: 'beta', status: 'failed', startedAtMs: 1_000, endedAtMs: 6_000, changedFiles: 0 }),
  ];
  const nowMs = 61_000;
  const lines = renderPoolPane('opencode', jobs, 60, { nowMs });
  assert.ok(lines[0]!.startsWith('╭') && lines[0]!.endsWith('╮'));
  assert.ok(lines.at(-1)!.startsWith('╰') && lines.at(-1)!.endsWith('╯'));
  assert.match(lines[0]!, /opencode/);
  assert.match(lines[1]!, /opencode · 2 jobs/);
  // 2 rows + 2 header-ish + top/bottom edges.
  assert.equal(lines.length, 2 + 3);
  assert.match(lines[0]!, /opencode/);
  const rowA = lines.find((l) => l.includes('alpha'))!;
  assert.ok(rowA.includes(POOL_GLYPHS.running), 'running glyph present');
  assert.match(rowA, /1m/); // 61_000 - 1_000 rounds down to the 1m bucket
  assert.match(rowA, /±3/);
  const rowB = lines.find((l) => l.includes('beta'))!;
  assert.ok(rowB.includes(POOL_GLYPHS.failed), 'failed glyph present');
  assert.match(rowB, /5s/); // terminal jobs use their end time, not nowMs
  assert.match(rowB, /±0/);
  assert.ok(fits(lines, 60));
});

test('empty pool renders a no-jobs line inside the box', () => {
  const lines = renderPoolPane('agy', [], 40);
  assert.match(lines.join('\n'), /no jobs/);
  assert.equal(lines.length, 4); // top, header, empty, bottom
  assert.ok(fits(lines, 40));
});

test('overflow collapses the tail into a +N more line', () => {
  const jobs = Array.from({ length: 12 }, (_, i) => job({ id: `j${i}`, title: `job ${i}` }));
  const lines = renderPoolPane('jules', jobs, 60, { maxRows: 8, nowMs: 0 });
  assert.ok(lines.some((l) => l.includes('+4 more')));
  // Exactly maxRows job rows. Count the running status glyph rather than the '·' header
  // separator, which also appears on the `jules · 12 jobs` header line.
  assert.equal(lines.filter((l) => l.includes(POOL_GLYPHS.running)).length, 8);
  // No jobs past the cap leak through.
  assert.ok(!lines.join('\n').includes('job 11'));
  // maxRows 0 still renders the overflow summary, not zero information.
  const zero = renderPoolPane('jules', jobs, 60, { maxRows: 0, nowMs: 0 });
  assert.ok(zero.some((l) => l.includes(`+12 more`)));
});

test('rows are clipped deterministically to the pane width (long titles, CJK)', () => {
  const jobs = [
    job({ id: 'long', title: '日本語のとても長いタイトルです superseded', status: 'running', startedAtMs: 0 }),
    job({ id: 'emoji', title: 'deploy 🚀 to ☁️ now', status: 'failed', startedAtMs: 0, endedAtMs: 1_000 }),
  ];
  const width = MIN_COLUMN_WIDTH; // 24 visible columns, the floor
  const lines = renderPoolPane('opencode', jobs, width, { nowMs: 1_000 });
  assert.ok(fits(lines, width), 'every line fits the requested width');
  // Deterministic: identical inputs produce identical output.
  assert.deepEqual(renderPoolPane('opencode', jobs, width, { nowMs: 1_000 }), lines);
});

test('clipToWidth is ANSI/wide-char aware and idempotent', () => {
  assert.equal(clipToWidth('', 5), '');
  assert.equal(clipToWidth('abc', 0), '');
  assert.equal(clipToWidth('abc', 5), 'abc');
  const clipped = clipToWidth('日本語テスト', 4);
  assert.ok(visibleWidth(clipped) <= 4);
  // Re-clipping must not stack ellipses.
  assert.equal(clipToWidth(clipped, 4), clipped);
  assert.equal(clipToWidth(clipped, 100), clipped);
});

test('allocateColumnWidths is deterministic and fills the width with blank separators', () => {
  const naturals = [80, 30, 40];
  const width = 100;
  const a = allocateColumnWidths(naturals, width, MIN_COLUMN_WIDTH);
  const b = allocateColumnWidths(naturals, width, MIN_COLUMN_WIDTH);
  assert.deepEqual(a, b, 'no randomness');
  assert.equal(a.reduce((x, y) => x + y, 0), width - (naturals.length - 1));
  for (const w of a) assert.ok(w >= MIN_COLUMN_WIDTH, 'each column honours the minimum');
  assert.ok(a.every((w) => Number.isInteger(w)));
});

test('split panes: native left, external columns right, all lines fit', () => {
  const native = {
    header: 'SUPERVISOR',
    rackLines: ['│ W03 ▶ running │', '│ W04 ? waiting │', '╰───────────────╯'],
  };
  const pools = [
    { pool: 'opencode' as const, jobs: [job({ title: 'opencode task', status: 'running' })] },
    { pool: 'agy' as const, jobs: [job({ title: 'agy task', status: 'succeeded', endedAtMs: 2_000 })] },
    { pool: 'jules' as const, jobs: [] }, // empty pools are omitted
  ];
  const W = 120;
  const lines = renderSplitPanes(native, pools, W, { nowMs: 2_000 });
  assert.ok(fits(lines, W), 'every composited line fits');
  assert.ok(lines[0]!.includes('SUPERVISOR'), 'native header stays leftmost');
  // Pool names appear on their header row (row 1): row 0 is the native header + top edges.
  const text = lines.join('\n');
  assert.ok(text.includes('opencode'), 'opencode column present');
  assert.ok(text.includes('agy'), 'agy column present');
  assert.ok(!text.includes('jules'), 'empty pool is omitted');
  // Columns are ordered left to right: native, opencode, agy.
  assert.ok(text.indexOf('SUPERVISOR') < text.indexOf('opencode'));
  assert.ok(text.indexOf('opencode') < text.indexOf('agy'));
});

test('split panes: native=null starts external columns at column 0', () => {
  const W = 80;
  const lines = renderSplitPanes(null, [{ pool: 'agy', jobs: [job({ title: 'cloud run', status: 'queued' })] }], W);
  assert.ok(lines.length > 0);
  assert.ok(lines[0]!.startsWith('╭'));
  assert.ok(fits(lines, W));
});

test('split panes: narrow terminal stacks vertically in stable pool order', () => {
  const native = { header: 'SUPERVISOR', rackLines: ['│ W03 ▶ running │'] };
  const pools = [
    { pool: 'opencode' as const, jobs: [job({ title: 'oc', status: 'running' })] },
    { pool: 'agy' as const, jobs: [job({ title: 'ay', status: 'queued' })] },
    { pool: 'jules' as const, jobs: [job({ title: 'jl', status: 'succeeded', endedAtMs: 1_500 })] },
  ];
  // 4 columns would need >= 24*4+3 = 99 columns; 40 forces the stack.
  const W = 40;
  const lines = renderSplitPanes(native, pools, W, { nowMs: 2_000 });
  assert.ok(fits(lines, W));
  // Vertically stacked: no single line carries two pool headers.
  const headers = lines.filter((l) => / op(encode|e)code · /.test(l) || / jules · /.test(l) || / agy · /.test(l));
  assert.ok(headers.every((l) => (l.match(/opencode|agy|jules/g) ?? []).length === 1));
  const text = lines.join('\n');
  const at = (s: string) => text.indexOf(s);
  assert.ok(at('SUPERVISOR') < at('opencode'));
  assert.ok(at('opencode') < at('agy'));
  assert.ok(at('agy') < at('jules'));
});

test('split panes: unequal column heights pad the shorter column with blanks', () => {
  const native = {
    header: 'SUPERVISOR',
    rackLines: ['l1', 'l2', 'l3', 'l4', 'l5', 'l6'],
  };
  const pools = [{ pool: 'opencode' as const, jobs: [job({ title: 'short', status: 'running' })] }];
  const W = 100;
  const lines = renderSplitPanes(native, pools, W, { nowMs: 1_000 });
  const nativeHeight = 1 + native.rackLines.length; // header + lines
  const poolHeight = 1 + 1 + 2; // own header + 1 job + top/bottom edges
  assert.ok(nativeHeight > poolHeight);
  assert.equal(lines.length, nativeHeight, 'height equals the tallest column');
  assert.ok(fits(lines, W));
  // Rows past the pool's height carry no pool box glyph.
  const tail = lines.slice(poolHeight);
  assert.ok(tail.length > 0);
  assert.ok(tail.every((l) => !l.includes('│ short') && !l.includes('opencode')), 'short column padded with blanks only');
  assert.deepEqual(renderSplitPanes(native, pools, W, { nowMs: 1_000 }), lines);
});

test('split panes: width 0 and empty inputs are safe no-ops', () => {
  assert.deepEqual(renderSplitPanes(null, [], 0), []);
  assert.deepEqual(renderSplitPanes(null, [], 80), []);
  assert.deepEqual(renderSplitPanes({ rackLines: [] }, [], 80), []);
  // A native-only column still pads to the allocated width so boxes never ragged-edge.
  const nativeOnly = renderSplitPanes({ rackLines: ['x'] }, [{ pool: 'agy', jobs: [] }], 80);
  assert.equal(nativeOnly.length, 1);
  assert.ok(nativeOnly[0]!.startsWith('x'));
  assert.equal(visibleWidth(nativeOnly[0]!), 80);
});

test('default max rows constants are sane', () => {
  assert.equal(DEFAULT_MAX_ROWS, 8);
  assert.equal(MIN_COLUMN_WIDTH, 24);
});
