import { truncateToWidth, visibleWidth } from '@earendil-works/pi-tui';

/**
 * Static supervisor panes for the external (non-Pi) worker pools.
 *
 * Native Pi workers keep the animated lamp rack in `ui/worker-rack.ts`; the three headless
 * pools cannot be animated (two are one-shot child processes, one is a cloud VM with no local
 * presence), so each gets its own static, boxed pane. `renderSplitPanes` is the single entry
 * point the operator calls after every state change: native rack on the left, one column per
 * non-empty external pool on the right.
 *
 * Pure and deterministic: no fs, no clock, no randomness. Everything time-related is passed in
 * explicitly as `nowMs`, exactly like `renderRack`.
 *
 * Reuse note: `ui/worker-rack.ts` keeps its `clip`/`pad` helpers private (not exported), so this
 * module exports its own ANSI/wide-char aware `clipToWidth`. If worker-rack ever exports one,
 * import it here instead of maintaining two copies.
 */

/** Stable pool order the operator iterates (`externalPoolIds()`). */
export type PoolId = 'native' | 'opencode' | 'agy' | 'jules';

/** Lifecycle of a single job in any pool. `unknown` is the fallback for unrecognised input. */
export type PoolJobStatus =
  | 'queued'
  | 'starting'
  | 'running'
  | 'waiting_input'
  | 'succeeded'
  | 'failed'
  | 'cancelled'
  | 'unknown';

/** Structural view of one pool job. Defined locally on purpose: `pools/*` is owned elsewhere. */
export interface PoolJobView {
  id: string;
  /** Short human-readable job/task title. */
  title: string;
  status: PoolJobStatus | string;
  /** Epoch ms when the job started, or `null`/absent while queued. */
  startedAtMs?: number | null;
  /** Epoch ms when the job ended; omitted while still running. */
  endedAtMs?: number | null;
  /** Number of changed files reported by the job. */
  changedFiles?: number;
}

/** One external pool column. `native` is intentionally excluded (it has its own pane). */
export interface PoolPaneInput {
  pool: Exclude<PoolId, 'native'>;
  jobs: PoolJobView[];
}

export interface PoolPaneOpts {
  /** Max job rows drawn before the `+N more` overflow line. Default 8. */
  maxRows?: number;
  /** Instant used to compute elapsed time for still-running jobs. Default 0 (pass a real clock). */
  nowMs?: number;
}

export interface SplitPaneOpts extends PoolPaneOpts {
  /** Max job rows per external column. Default 8. */
  maxRowsPerPane?: number;
  /** Minimum visible width of a single column. Default 24. */
  minColumnWidth?: number;
}

export interface NativePaneInput {
  /** Lines from `renderRack` (or any other renderer); padded/truncated to the column. */
  rackLines: string[];
  /** Optional title drawn as the native pane header. */
  header?: string;
}

/** Single-width glyphs, distinct in feel from the animated lamp bulbs but consistent with them. */
export const POOL_GLYPHS: Record<PoolJobStatus, string> = {
  queued: '·',
  starting: '◌',
  running: '▶',
  waiting_input: '?',
  succeeded: '✓',
  failed: '✗',
  cancelled: '—',
  unknown: '~',
};

/** Semantic Pi theme tokens per status. Mirrors `SYMBOLS[*].token` in ui/worker-rack.ts. */
export const POOL_TOKENS: Record<PoolJobStatus, string> = {
  queued: 'muted',
  starting: 'accent',
  running: 'success',
  waiting_input: 'warning',
  succeeded: 'success',
  failed: 'error',
  cancelled: 'dim',
  unknown: 'muted',
};

/** Minimum visible width of any single pane column. Below this the split stacks vertically. */
export const MIN_COLUMN_WIDTH = 24;
/** Default maximum job rows shown per pane before the overflow line. */
export const DEFAULT_MAX_ROWS = 8;
/** Vertical box edges — single-width, same idiom as ui/worker-rack.ts. */
const TOP_LEFT = '╭';
const TOP_RIGHT = '╮';
const BOTTOM_LEFT = '╰';
const BOTTOM_RIGHT = '╯';
const HORIZONTAL = '─';
const VERTICAL = '│';
const ELL = '…';
const DASH = '—';

/**
 * Ordered list of non-native pools. Kept here so `operator.ts` never duplicates the list.
 */
export function externalPoolIds(): Array<Exclude<PoolId, 'native'>> {
  return ['opencode', 'agy', 'jules'];
}

function rankOf(pool: string): number {
  const order = externalPoolIds();
  const i = order.indexOf(pool as Exclude<PoolId, 'native'>);
  return i === -1 ? order.length : i;
}

/** Glyph for a status, with `unknown` as the fallback for unrecognised values. */
export function poolGlyph(status: string): string {
  return POOL_GLYPHS[status as PoolJobStatus] ?? POOL_GLYPHS.unknown;
}

function normalizeStatus(status: string): PoolJobStatus {
  return status in POOL_GLYPHS ? (status as PoolJobStatus) : 'unknown';
}

/** ANSI/wide-char aware clip to `w` visible columns. */
export function clipToWidth(s: string, w: number): string {
  if (w <= 0) return '';
  if (visibleWidth(s) <= w) return s;
  // Drop a trailing ellipsis first so re-clipping never stacks "………".
  const body = s.endsWith(ELL) ? s.slice(0, -ELL.length) : s;
  return truncateToWidth(body, w, ELL);
}

/** ANSI/wide-char aware pad to exactly `w` visible columns (pads with spaces, never clips mid-glyph). */
function padToWidth(s: string, w: number): string {
  const c = clipToWidth(s, w);
  return c + ' '.repeat(Math.max(0, w - visibleWidth(c)));
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, n));
}

/** `45s`, `12m`, `3h`, `2d` — compact, single-unit, deterministic. */
export function formatElapsed(ms: number): string {
  const s = Math.max(0, Math.floor((Number.isFinite(ms) ? ms : 0) / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

/** Elapsed for one job at instant `nowMs`; terminal jobs use their recorded end time. */
function elapsedOf(job: PoolJobView, nowMs: number): string {
  const started = typeof job.startedAtMs === 'number' ? job.startedAtMs : null;
  if (started === null) return DASH;
  const ended = typeof job.endedAtMs === 'number' ? job.endedAtMs : nowMs;
  return formatElapsed(ended - started);
}

function filesOf(job: PoolJobView): string {
  const n = Math.max(0, Math.floor(job.changedFiles ?? 0));
  return `±${n}`;
}

function jobTitle(job: PoolJobView): string {
  return job.title || job.id || '';
}

/** The natural one-column width of a job row: glyph + elapsed + title + file count. */
function naturalRowWidth(job: PoolJobView, nowMs: number): number {
  return (
    visibleWidth(POOL_GLYPHS.unknown) +
    1 +
    visibleWidth(elapsedOf(job, nowMs)) +
    1 +
    visibleWidth(jobTitle(job)) +
    1 +
    visibleWidth(filesOf(job))
  );
}

/**
 * Natural width of a pool pane: longest job row (over all jobs, so the header does not jump as
 * rows overflow) and the header/title text, plus the box chrome, clamped to at least MIN.
 */
export function poolNaturalWidth(pool: PoolId, jobs: PoolJobView[], nowMs: number): number {
  let inner = visibleWidth(pool);
  for (const job of jobs) inner = Math.max(inner, naturalRowWidth(job, nowMs));
  const header = visibleWidth(`${pool} · ${jobs.length} job${jobs.length === 1 ? '' : 's'}`);
  inner = Math.max(inner, header);
  return Math.max(MIN_COLUMN_WIDTH, inner + 6);
}

/** Natural width of a native rack column (longest rack line, plus the optional header). */
function nativeNaturalWidth(native: NativePaneInput): number {
  let w = native.header ? visibleWidth(native.header) : 0;
  for (const line of native.rackLines) w = Math.max(w, visibleWidth(line));
  return Math.max(MIN_COLUMN_WIDTH, w);
}

/** A top/bottom box edge that is exactly `width` visible columns. */
function boxEdge(width: number, left: string, right: string): string {
  return left + HORIZONTAL.repeat(Math.max(0, width - 2)) + right;
}

/**
 * A top box edge with the pool name embedded, e.g. `╭─ opencode ──────╮`, exactly `width` wide.
 * Keeps the pane identifiable after it is clipped or stacked; the count-bearing header row is
 * still emitted separately so jobs/empty-state text stays parseable.
 */
function titledEdge(width: number, title: string): string {
  const inner = Math.max(0, width - 2);
  const label = `─ ${title} `;
  const lw = visibleWidth(label);
  if (lw >= inner) return TOP_LEFT + clipToWidth(label, inner) + TOP_RIGHT;
  return TOP_LEFT + label + HORIZONTAL.repeat(inner - lw) + TOP_RIGHT;
}

/**
 * Static boxed pane for one external pool.
 *
 * Layout per row: `│ <glyph> <elapsed> <title> <files> │`. Rows are clipped to `width`.
 * Empty pools render a dim `no jobs` line inside the box. Beyond `maxRows`, a single
 * `+N more` line replaces the tail.
 */
export function renderPoolPane(pool: PoolId, jobs: PoolJobView[], width: number, opts: PoolPaneOpts = {}): string[] {
  const w = Math.max(MIN_COLUMN_WIDTH, Math.floor(width));
  const nowMs = opts.nowMs ?? 0;
  const maxRows = Math.max(0, Math.floor(opts.maxRows ?? DEFAULT_MAX_ROWS));
  const lines: string[] = [];
  const header = `${pool} · ${jobs.length} job${jobs.length === 1 ? '' : 's'}`;
  lines.push(titledEdge(w, pool));
  lines.push(`${VERTICAL} ${padToWidth(header, w - 4)} ${VERTICAL}`);

  if (jobs.length === 0) {
    lines.push(`${VERTICAL} ${padToWidth('no jobs', w - 4)} ${VERTICAL}`);
    lines.push(boxEdge(w, BOTTOM_LEFT, BOTTOM_RIGHT));
    return lines;
  }

  const shown = jobs.slice(0, maxRows);
  for (const job of shown) {
    const glyph = poolGlyph(job.status);
    const body = `${glyph} ${elapsedOf(job, nowMs)} ${jobTitle(job)} ${filesOf(job)}`;
    lines.push(`${VERTICAL} ${padToWidth(body, w - 4)} ${VERTICAL}`);
  }
  if (jobs.length > shown.length) {
    lines.push(`${VERTICAL} ${padToWidth(`+${jobs.length - shown.length} more`, w - 4)} ${VERTICAL}`);
  }
  lines.push(boxEdge(w, BOTTOM_LEFT, BOTTOM_RIGHT));
  return lines;
}

/**
 * Allocate one visible width per column.
 *
 * Rule (deterministic, documented, tested): each column gets a share proportional to its natural
 * width, clamped into [minColumnWidth, floor(width / columns)]. The rounding remainder is moved
 * onto the widest column (ties resolve to the leftmost); if the clamped sum overshoots, the
 * deficit is carved from the widest column first, then right-to-left, never below the minimum.
 * Columns plus their blank separators exactly fill `width`. No Math.random, no Date.now.
 */
export function allocateColumnWidths(naturals: number[], width: number, minColumnWidth = MIN_COLUMN_WIDTH): number[] {
  const n = naturals.length;
  if (n === 0) return [];
  const usable = width - (n - 1); // one blank separator column between panes
  const cap = Math.max(minColumnWidth, Math.floor(width / n));
  const min = Math.min(minColumnWidth, Math.max(1, Math.floor(usable / n)));
  const sumNat = naturals.reduce((a, b) => a + Math.max(1, b), 0);
  const alloc = naturals.map((nat) => {
    const raw = Math.floor((usable * Math.max(1, nat)) / sumNat);
    return clamp(raw, min, cap);
  });

  // Ties resolve to the leftmost widest column, so allocation stays deterministic.
  let widest = 0;
  for (let i = 1; i < n; i++) if (naturals[i]! > naturals[widest]!) widest = i;

  let delta = usable - alloc.reduce((a, b) => a + b, 0);
  if (delta < 0) {
    const order = [widest];
    for (let i = n - 1; i >= 0; i--) if (i !== widest) order.push(i);
    for (const i of order) {
      if (delta === 0) break;
      const take = Math.min(-delta, alloc[i]! - min);
      alloc[i]! -= take;
      delta += take;
    }
  } else if (delta > 0) {
    // Remainder goes to the widest column in one shot (may exceed the proportional cap; total is what matters).
    alloc[widest]! += delta;
    delta = 0;
  }
  return alloc;
}

function blankLine(width: number): string {
  return ' '.repeat(Math.max(0, width));
}

/** Pad a native pane to `width` and give it an optional header line. */
function renderNativeColumn(native: NativePaneInput, width: number): string[] {
  const body = native.rackLines.map((line) => padToWidth(line, width));
  if (!native.header) return body;
  return [padToWidth(native.header, width), ...body];
}

/**
 * Compose native + external panes across the terminal width.
 *
 * Wide terminals: side-by-side, native (if any) at column 0, then each non-empty external pool in
 * the stable order opencode, agy, jules, with one blank separator column between panes. Columns
 * are width-proportional (see `allocateColumnWidths`) and every pane is padded to the tallest
 * column so the boxes align; shorter columns pad with blank lines (no stray borders).
 *
 * Narrow terminals: when `width < minColumnWidth * columnCount + (columnCount - 1)` — the width
 * at which every column could still be at least 24 wide with one blank separator each — the
 * layout degrades by **stacking vertically** in the order native, opencode, agy, jules, each
 * rendered at the full available width. This rule is fixed and documented so callers and tests
 * agree on it.
 */
export function renderSplitPanes(
  native: NativePaneInput | null,
  pools: PoolPaneInput[],
  width: number,
  opts: SplitPaneOpts = {},
): string[] {
  const W = Math.max(0, Math.floor(width));
  if (W === 0) return [];
  const maxRows = opts.maxRowsPerPane ?? opts.maxRows ?? DEFAULT_MAX_ROWS;
  const minColumnWidth = opts.minColumnWidth ?? MIN_COLUMN_WIDTH;
  const nowMs = opts.nowMs ?? 0;

  const hasNative = !!native && (native.rackLines.length > 0 || !!native.header);
  const external = (pools ?? [])
    .filter((p): p is PoolPaneInput => !!p && (p.pool as PoolId) !== 'native' && Array.isArray(p.jobs) && p.jobs.length > 0)
    .slice()
    .sort((a, b) => rankOf(a.pool) - rankOf(b.pool));

  const columnCount = (hasNative ? 1 : 0) + external.length;

  // -- Degradation rule: stack vertically when side-by-side cannot give every column >= min width.
  if (columnCount === 0) return [];
  const sideBySideMin = minColumnWidth * columnCount + (columnCount - 1);
  if (columnCount > 1 && W < sideBySideMin) {
    const stacked: string[] = [];
    if (hasNative && native) stacked.push(...renderNativeColumn(native, W));
    for (const pool of external) stacked.push(...renderPoolPane(pool.pool, pool.jobs, W, { maxRows, nowMs }));
    return stacked.map((line) => clipToWidth(line, W));
  }

  // -- Side-by-side.
  const columns: Array<{ natural: number; render: (w: number) => string[] }> = [];
  if (hasNative && native) {
    columns.push({ natural: nativeNaturalWidth(native), render: (w) => renderNativeColumn(native, w) });
  }
  for (const pool of external) {
    columns.push({
      natural: poolNaturalWidth(pool.pool, pool.jobs, nowMs),
      render: (w) => renderPoolPane(pool.pool, pool.jobs, w, { maxRows, nowMs }),
    });
  }

  const widths = allocateColumnWidths(
    columns.map((c) => c.natural),
    W,
    minColumnWidth,
  );
  const rendered = columns.map((c, i) => c.render(widths[i]!));
  const height = rendered.reduce((h, col) => Math.max(h, col.length), 0);

  const out: string[] = [];
  for (let row = 0; row < height; row++) {
    const cells = rendered.map((col, i) => (row < col.length ? col[row]! : blankLine(widths[i]!)));
    out.push(clipToWidth(cells.join(' '), W));
  }
  return out;
}
