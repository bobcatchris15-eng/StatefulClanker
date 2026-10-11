import { truncateToWidth, visibleWidth } from '@earendil-works/pi-tui';
import { activityOf, ACTIVE_STATES, DEFAULT_LAMPS, lampColor, lampOn } from './lamp-bank.ts';

export interface RackWorker {
  id: string; display_name?: string; status: string; model: string; current_action?: string; current_tool?: string; role?: string; task_id?: string;
  /** Human-readable task/job title. Supplied by the caller (registry has only `task_id`). */
  task_title?: string;
}

export interface RackTheme {
  /** Matches Pi's `Theme.fg(token, text)`; tokens are semantic (see pi theme ThemeColor). */
  fg(token: string, text: string): string;
}

export interface RackOpts {
  /** Active Pi theme. When omitted the panel renders plain text (no hardcoded colours). */
  theme?: RackTheme;
  /** Max worker rows drawn before an overflow line. Default 8. */
  maxRows?: number;
  /** Lamp sockets per worker. Default 6; shrinks on narrow terminals. */
  maxLamps?: number;
  /**
   * Animation time in ms (see `RackClock.elapsedMs`). Every lamp is an independent
   * oscillator evaluated at this instant, so the whole rack moves with no shared phase.
   */
  nowMs?: number;
  /** Injectable lamp predicate, for tests. Defaults to the real per-lamp oscillator. */
  lit?: (id: string, index: number) => boolean;
  /** Draw the state legend inside the box (fullscreen console). */
  legend?: boolean;
}

export const DEFAULT_MAX_ROWS = 8;
/** Below this width the box is dropped and rows render as bare stripped lines. */
export const MIN_BOX_WIDTH = 24;
/** Space reserved around a lamp bank cell: one space each side. */
const BANK_PAD = 2;

export const SYMBOLS: Record<string, { sym: string; label: string; token: string }> = {
  RUNNING: { sym: '*', label: 'RUN', token: 'success' },
  STARTING: { sym: '+', label: 'START', token: 'accent' },
  WAITING: { sym: '~', label: 'WAIT', token: 'warning' },
  BLOCKED: { sym: '!', label: 'BLOCK', token: 'error' },
  COMPLETE: { sym: 'v', label: 'DONE', token: 'success' },
  FAILED: { sym: 'x', label: 'FAIL', token: 'error' },
  CANCELLED: { sym: '-', label: 'CANCEL', token: 'dim' },
  LOST: { sym: '#', label: 'LOST', token: 'error' },
  IDLE: { sym: 'o', label: 'IDLE', token: 'muted' },
};

/** Header segment priority: supervisor wants RUN/WAIT/FAIL visible before the rest. */
const HEADER_ORDER = ['RUNNING', 'WAITING', 'BLOCKED', 'FAILED', 'LOST', 'STARTING', 'COMPLETE', 'IDLE'];
const UNKNOWN = { sym: '?', label: '?', token: 'muted' };

const ELL = '…';
/** Dark, unlit socket. Keeps every socket the same column count as a lit lamp. */
const SOCKET = '·';

/**
 * Bulb glyphs, cycled by socket index so a bank reads as a row of different lamps rather
 * than one repeated character. All are single-width box glyphs.
 */
const LAMP_SYMS = ['█', '▓', '▒'];


function status(w: RackWorker): { sym: string; label: string; token: string } {
  return SYMBOLS[w.status] ?? { ...UNKNOWN, label: w.status || UNKNOWN.label };
}

/** ANSI/wide-char aware clip to `w` visible columns. */
function clip(s: string, w: number): string {
  if (w <= 0) return '';
  return visibleWidth(s) <= w ? s : truncateToWidth(s, w, ELL);
}

/** ANSI/wide-char aware pad to exactly `w` visible columns. */
function pad(s: string, w: number): string {
  const c = clip(s, w);
  return c + ' '.repeat(Math.max(0, w - visibleWidth(c)));
}

function jobLabel(w: RackWorker): string {
  return w.task_title || w.task_id || '';
}

/** Stable grouping: in-flight workers first, then idle, then finished; id order within a group. */
function ordered(workers: RackWorker[]): RackWorker[] {
  const rank = (w: RackWorker): number => {
    if (ACTIVE_STATES.has(w.status)) return 0;
    if (w.status === 'IDLE') return 1;
    return 2;
  };
  return [...workers].sort((a, b) => rank(a) - rank(b) || a.id.localeCompare(b.id));
}

/**
 * The lamp bank cell: `depth` fixed sockets, each an independent oscillator.
 *
 * No lamp here can see any other lamp. Each has its own period, phase offset, duty,
 * segment count and per-cycle skip, so at any instant a bank is a random-looking
 * scatter - which is the entire point. Lit lamps pick a colour per ignition; dark
 * sockets are drawn, not skipped, so the cell width never changes and the columns
 * never jitter as lamps switch.
 */
function bank(w: RackWorker, depth: number, tMs: number, st: (t: string, s: string) => string, opts: RackOpts): string {
  const act = activityOf(w.status);
  const out: string[] = [];
  for (let i = 0; i < depth; i++) {
    const on = opts.lit ? opts.lit(w.id, i) : lampOn(w.id, i, tMs, act);
    const bulb = LAMP_SYMS[i % LAMP_SYMS.length]!;
    out.push(on ? (opts.theme ? `\u001b[${lampColor(w.id, i, tMs)}m${bulb}\u001b[39m` : bulb) : st('dim', SOCKET));
  }
  return out.join('');
}

/** Compact one-line form used below MIN_BOX_WIDTH and in tests. */
function compact(w: RackWorker, depth: number, tMs: number, st: (t: string, s: string) => string, opts: RackOpts): string {
  const s = status(w);
  const act = w.current_action || w.current_tool || '';
  const glyph = st(s.token, s.sym);
  return [w.id, w.display_name ?? '', glyph, bank(w, depth, tMs, st, opts), s.label, jobLabel(w) || w.model, act].filter(Boolean).join(' ').trimEnd();
}

/** `SUPERVISOR · RUN 2 · WAIT 1 · … · jobs 1/3`, sized to `budget` visible columns. */
function header(workers: RackWorker[], budget: number, st: (t: string, s: string) => string): string {
  const counts = new Map<string, number>();
  for (const w of workers) counts.set(w.status, (counts.get(w.status) ?? 0) + 1);

  const segs: string[] = [];
  let used = 0;
  for (const s of HEADER_ORDER) {
    const n = counts.get(s) ?? 0;
    if (!n) continue;
    const meta = SYMBOLS[s] ?? UNKNOWN;
    const seg = `${st('muted', meta.label)} ${st(meta.token, `${n}`)}`;
    const cost = visibleWidth(seg) + 3; // " · " separator
    if (used + cost > budget) continue;
    used += cost;
    segs.push(seg);
  }
  if (!segs.length && budget >= 4) segs.push(st('muted', `n=${workers.length}`));
  return segs.join(`${st('muted', ' · ')} `);
}

/** `●RUN ◌START ◐WAIT …` state legend, one coloured glyph+label per state. */
function legend(st: (t: string, s: string) => string): string {
  return Object.keys(SYMBOLS)
    .map((k) => { const m = SYMBOLS[k]!; return `${st(m.token, m.sym)}${st('muted', m.label)}`; })
    .join(' ');
}

interface Budget { idW: number; nameW: number; taskW: number; modelW: number; lamps: number; rest: number }

/**
 * Column plan. `rest` is the leftover space after id/name/task/model, i.e. the action
 * column. The lamp bank is allocated first (it is the whole point of the panel) and
 * shrinks before any text column does.
 */
function plan(rows: RackWorker[], cw: number, wantLamps: number): Budget {
  const idW = Math.max(3, ...rows.map((w) => visibleWidth(w.id)));
  const longest = Math.max(6, ...rows.map((w) => visibleWidth(w.display_name || '')));
  const nameW = Math.min(20, longest);
  // glyph, space, bank, space
  const fixed = 2 + 1 + wantLamps + 1;
  // Never let the bank eat the id or name columns: floor it at the text minimum.
  let lamps = Math.max(1, Math.min(wantLamps, Math.max(1, cw - fixed - idW - 1 - 1 - 6)));
  const used0 = 2 + lamps + 1 + idW + 1 + nameW; // glyph, bank, id, name
  const ACTION_MIN = 10;
  let rest = cw - used0 - 1; // trailing space after the name
  const modelMax = Math.min(14, Math.max(0, ...rows.map((w) => visibleWidth(w.model))));
  let taskW = 0;
  let modelW = 0;
  if (rest >= 8 + 1 + modelMax + 1 + ACTION_MIN) taskW = Math.min(28, Math.max(10, Math.floor(rest * 0.35)));
  else if (rest >= 8 + 1 + ACTION_MIN) taskW = Math.min(20, rest - 1 - ACTION_MIN);
  if (taskW > 0) rest -= taskW + 1;
  if (modelMax > 0 && rest >= modelMax + 1 + ACTION_MIN) { modelW = modelMax; rest -= modelMax + 1; }
  return { idW, nameW, taskW, modelW, lamps, rest };
}

/** One worker row: `<glyph> <bank> <id> <name>  <task> <model> ... <action>`. */
function row(w: RackWorker, b: Budget, tMs: number, st: (t: string, s: string) => string, opts: RackOpts): string {
  const s = status(w);
  // The head glyph is steady: it is the meaning anchor. All the motion lives in the lamps,
  // so state stays readable while the bank flickers asynchronously.
  const head = st(s.token, s.sym);
  const act = w.current_action || w.current_tool || (SYMBOLS[w.status] ? '' : w.status);
  const cells: string[] = [pad(w.id, b.idW), pad(w.display_name || '', b.nameW)];
  const left = `${head} ${bank(w, b.lamps, tMs, st, opts)} ${cells.join(' ')}`;
  let tail = '';
  if (b.taskW > 0) tail += `${pad(clip(jobLabel(w), b.taskW), b.taskW)} `;
  if (b.modelW > 0) tail += `${st('dim', pad(clip(w.model, b.modelW), b.modelW))} `;
  const space = Math.max(0, b.rest);
  const action = space > 3 ? st('muted', clip(act, space)) : '';
  return `${left} ${tail}${' '.repeat(Math.max(0, space - visibleWidth(action)))}${action}`;
}

/**
 * Pure: workers -> display lines for an available terminal `width`.
 * Boxed supervisor panel (header with per-state counts + job count) at width >= MIN_BOX_WIDTH,
 * bare stripped lines below that. Never emits a line wider than `width`, and always emits
 * at least one line (idle placeholder when there are no workers).
 */
export function renderRack(workers: RackWorker[], width: number, opts: RackOpts = {}): string[] {
  const W = Math.max(0, Math.floor(width));
  const theme = opts.theme;
  const st = (t: string, s: string): string => (theme ? theme.fg(t, s) : s);
  const tMs = opts.nowMs ?? 0;
  const rows = ordered(workers ?? []);
  const maxLamps = Math.max(1, Math.floor(opts.maxLamps ?? DEFAULT_LAMPS));

  if (W <= 0) return [];
  if (W < MIN_BOX_WIDTH) {
    const depth = Math.max(1, Math.min(maxLamps, W - 14));
    const lines = rows.length ? rows.map((w) => compact(w, depth, tMs, st, opts)) : [st('muted', '○ idle — no workers')];
    return lines.map((l) => clip(l, W));
  }

  const cw = W - 4;
  const maxRows = Math.max(1, Math.floor(opts.maxRows ?? DEFAULT_MAX_ROWS));
  const shown = rows.slice(0, maxRows);
  const hidden = rows.length - shown.length;

  const body: string[] = [];
  if (!shown.length) body.push(st('muted', '○ idle — no workers spawned'));
  else {
    const b = plan(shown, cw, maxLamps);
    for (const w of shown) body.push(row(w, b, tMs, st, opts));
  }
  if (hidden > 0) body.push(st('muted', `… +${hidden} more (see /worker_list)`));
  if (opts.legend) body.push(st('muted', `lamp ${SOCKET}=dark socket ${LAMP_SYMS.join('')}=lit, each bulb on its own unsynchronized timer`));
  if (opts.legend) body.push(legend(st));

  // Header line carries the supervisor totals; the box is closed by a plain rule.
  const title = st('accent', ' SUPERVISOR ');
  const activeJobs = new Set(rows.filter((w) => ACTIVE_STATES.has(w.status)).map(jobLabel).filter(Boolean)).size;
  const totalJobs = new Set(rows.map(jobLabel).filter(Boolean)).size;
  const jobs = ` ${st('muted', 'jobs')} ${st(activeJobs ? 'accent' : 'muted', `${activeJobs}/${totalJobs}`)} `;
  const headBudget = cw - visibleWidth(title) - visibleWidth(jobs) - 4;
  const counts = header(rows, headBudget, st);
  let head = `┌${title}${counts ? `${st('muted', ' · ')}${counts}` : ''}${jobs}`;
  head += '─'.repeat(Math.max(0, W - 1 - visibleWidth(head))) + '┐';
  head = clip(head, W);

  const lines = [head, ...body.map((l) => clip(`│ ${pad(l, cw)} │`, W)), `└${'─'.repeat(Math.max(0, W - 2))}┘`];
  return lines.map((l) => clip(l, W));
}
