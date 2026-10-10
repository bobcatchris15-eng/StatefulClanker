/**
 * Blinkenlight lamp field: the stateful half of the supervisor rack.
 *
 * The look we are after is a 1970s mainframe front panel: a row of real bulbs per
 * worker, each driven by its OWN oscillator. Nothing is shared, nothing is aligned.
 * Every lamp has its own period, its own phase offset, its own duty cycle, its own
 * number of on/off segments per cycle, and a per-cycle coin flip that skips the whole
 * cycle entirely. A shared ticker is fine as long as no lamp can be observed marching
 * in step with another.
 *
 * Rendering is pure and lives in `worker-rack.ts`; this module owns the mutable state
 * (which workers are on the panel, what colour their bulbs burn) plus the animation
 * clock. Both are injectable so the renderer stays unit-testable without a terminal.
 */

/** Lamps per worker. The human asked for "5 or 6", so: six sockets, always. */
export const DEFAULT_LAMPS = 6;
/** The fullscreen `/rack` console shows the same bank per worker. */
export const LARGE_LAMPS = 6;

/** Fastest lamp oscillator. Below ~120ms a panel reads as a strobe, not as bulbs. */
export const MIN_PERIOD_MS = 140;
/** Slowest lamp oscillator. */
export const MAX_PERIOD_MS = 1_700;
/** Tick interval the operator's animation ticker aims for. */
export const TICK_MS = 100;
/**
 * Largest dt a single clock tick may contribute. A suspended laptop or a blocking tool
 * call must not make the lamps jump forward by minutes when the process wakes.
 */
export const MAX_DT_MS = 500;

/** States that count as "in flight" for ordering, job counts and lamp activity. */
export const ACTIVE_STATES = new Set(['STARTING', 'RUNNING', 'WAITING', 'BLOCKED']);

export interface RackRowLike { id: string; status: string }

/**
 * Which workers are on the panel and what their lamps burn.
 *
 * There is no scroll history any more: the sockets are fixed hardware, not a ticker
 * tape of past status changes. `sync()` only tracks liveness and current status (which
 * supplies the lamp colour), and is idempotent, so calling it on every draw is free.
 */
export class LampField {
  private live = new Map<string, { status: string; at: number }>();
  private cap: number;

  constructor(cap: number = DEFAULT_LAMPS) { this.cap = cap; }

  /** Sockets per worker for this field. */
  get depth(): number { return this.cap; }

  /** Record liveness + current status. Never appends, never allocates per lamp. */
  sync(workers: RackRowLike[], now: number): void {
    for (const w of workers) {
      const cur = this.live.get(w.id);
      if (!cur) { this.live.set(w.id, { status: w.status, at: now }); continue; }
      if (cur.status !== w.status) { cur.status = w.status; cur.at = now; }
    }
  }

  /** Last known status for a worker, or undefined if it was never seen. */
  statusOf(id: string): string | undefined { return this.live.get(id)?.status; }

  /**
   * Drop workers that have left the registry, so a long operator session does not
   * accumulate entries for every worker ever spawned.
   */
  prune(liveIds: Iterable<string>, ttlMs = 60_000, now = Date.now()): void {
    const live = new Set(liveIds);
    for (const [id, rec] of this.live) {
      if (live.has(id)) continue;
      if (now - rec.at > ttlMs) this.live.delete(id);
    }
  }

  clear(): void { this.live.clear(); }
}

/**
 * Animation clock: a monotonic elapsed-milliseconds counter with a clamped step.
 *
 * It is deliberately NOT a phase. A single shared phase is exactly the bug this design
 * avoids - every lamp would become a pure function of the same number. Advancing is a
 * pure function of the deltas passed in, so tests can pin an exact instant and get
 * byte-identical output.
 */
export class RackClock {
  /** Animation time in ms since the last reset. All lamp maths is a function of this. */
  elapsedMs = 0;
  /** -1 means "no baseline yet"; 0 is a legitimate timestamp. */
  private last = -1;

  /** Advance to `nowMs`; returns true when the rendered output could have changed. */
  advance(nowMs: number): boolean {
    if (this.last < 0) { this.last = nowMs; return false; }
    const dt = Math.max(0, Math.min(nowMs - this.last, MAX_DT_MS));
    this.last = nowMs;
    if (dt === 0) return false;
    this.elapsedMs += dt;
    return true;
  }

  reset(): void { this.elapsedMs = 0; this.last = -1; }
}

/* ------------------------------------------------------------------ *
 * Per-lamp randomness
 * ------------------------------------------------------------------ */

/** 32-bit FNV-1a over a string. Stable across runs, so lamps do not reshuffle per frame. */
function hash32(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

/** Deterministic pseudo-random in [0,1) from a seed and a salt. No Math.random anywhere. */
function rand(seed: number, salt: number): number {
  let h = (seed ^ Math.imul(salt + 1, 0x9e3779b1)) >>> 0;
  h ^= h >>> 15; h = Math.imul(h, 0x85ebca6b) >>> 0;
  h ^= h >>> 13; h = Math.imul(h, 0xc2b2ae35) >>> 0;
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

/** The immutable personality of one lamp: which oscillator it is wired to. */
export interface LampSpec {
  /** Base cycle length, ms. */
  periodMs: number;
  /** Phase offset into the cycle, ms. This is what de-aligns the rack at t=0. */
  offsetMs: number;
  /** Nominal on-fraction of the cycle. */
  duty: number;
  /** On/off segments per cycle (1..3): one lamp gets a steady glow, another a stutter. */
  segments: number;
}

/** Wire-up for lamp `index` of worker `id`. Pure, stable, cheap enough to call per frame. */
export function lampSpec(id: string, index: number): LampSpec {
  const h = hash32(`${id}#${index}`);
  const periodMs = MIN_PERIOD_MS + rand(h, 1) * (MAX_PERIOD_MS - MIN_PERIOD_MS);
  return {
    periodMs,
    offsetMs: rand(h, 2) * periodMs,
    duty: 0.26 + rand(h, 3) * 0.52,
    segments: 1 + Math.floor(rand(h, 4) * 3),
  };
}

/** How busy a worker is, 0..1. Feeds lamp density without synchronising anything. */
export function activityOf(status: string): number {
  if (status === 'RUNNING') return 1;
  if (ACTIVE_STATES.has(status)) return 0.7;
  if (status === 'IDLE') return 0.25;
  return 0.12; // finished / failed / lost: the bulbs are still wired, just barely
}

/**
 * Is lamp `index` of worker `id` lit at animation time `tMs`?
 *
 * Everything here is per lamp: its own period, its own offset, its own duty, its own
 * segment count, and a per-cycle coin flip that both skips the cycle outright and
 * re-jitters the duty. `activity` (0..1) scales the duty and the chance of a skipped
 * cycle, so a busy worker looks busy and a finished one looks nearly dead - without
 * any two lamps ever agreeing on when to change.
 */
export function lampOn(id: string, index: number, tMs: number, activity = 1, spec?: LampSpec): boolean {
  const s = spec ?? lampSpec(id, index);
  const seed = hash32(`${id}#${index}`);
  const t = tMs + s.offsetMs;
  const cycle = Math.floor(t / s.periodMs);
  const slot = cycle % 4096; // bounded so the per-cycle hash stays cheap forever
  if (rand(seed, 1000 + slot) < 0.45 * (1 - activity)) return false; // this cycle is dark
  const jitter = rand(seed, 5000 + slot);
  const duty = Math.min(0.92, Math.max(0.04, s.duty * (0.5 + 1.0 * jitter) * (0.6 + 0.6 * activity)));
  const u = (t % s.periodMs) / s.periodMs;
  return ((u * s.segments) % 1) < duty;
}

/** Which lamps are lit at `tMs` for one worker, index 0 first. */
export function litLamps(id: string, depth: number, tMs: number, activity = 1): boolean[] {
  const out: boolean[] = [];
  for (let i = 0; i < depth; i++) out.push(lampOn(id, i, tMs, activity));
  return out;
}
