/**
 * Blinkenlight lamp banks: the stateful half of the supervisor rack.
 *
 * Rendering is pure and lives in `worker-rack.ts`; this module owns the mutable
 * state (which lamps each worker has lit, and when) plus the animation clock.
 * Both are injectable so the renderer stays unit-testable without a terminal.
 */

/** One lamp: the state a worker was in, and when that lamp was lit. */
export interface Lamp { status: string; at: number }

/** A worker's lamp bank, oldest first. Index `length - 1` is the newest (rightmost) lamp. */
export type Bank = Lamp[];

/** Default bank depth for the always-on widget strip. */
export const DEFAULT_LAMPS = 8;
/** Bank depth for the fullscreen `/rack` console. */
export const LARGE_LAMPS = 24;
/** Blink cycle length. 400ms == 2.5Hz, one full on/off cycle. */
export const BLINK_PERIOD_MS = 400;
/**
 * Largest dt a single clock tick may contribute. A suspended laptop or a blocking
 * tool call must not make the lamps jump forward by minutes when the process wakes.
 */
export const MAX_DT_MS = 500;

/** States that count as "in flight" for ordering, job counts, header totals and blinking. */
export const ACTIVE_STATES = new Set(['STARTING', 'RUNNING', 'WAITING', 'BLOCKED']);

export interface RackRowLike { id: string; status: string }

/**
 * Per-worker lamp banks with a bounded total size.
 *
 * `sync()` is idempotent: it appends a lamp only when a worker's status actually
 * changed, so calling it on every draw does not flood the bank.
 */
export class LampBank {
  private banks = new Map<string, Bank>();
  private cap: number;

  constructor(cap: number = LARGE_LAMPS) { this.cap = cap; }

  /** Append a lamp for `status` if it differs from the worker's current lamp. */
  sync(workers: RackRowLike[], now: number): void {
    for (const w of workers) {
      const bank = this.banks.get(w.id);
      if (!bank) { this.banks.set(w.id, [{ status: w.status, at: now }]); continue; }
      if (bank[bank.length - 1]!.status !== w.status) {
        bank.push({ status: w.status, at: now });
        if (bank.length > this.cap) bank.splice(0, bank.length - this.cap);
      }
    }
  }

  /** Force a lamp onto a worker's bank (used to seed an initial lamp for a new worker). */
  push(id: string, status: string, at: number): void {
    this.sync([{ id, status }], at);
  }

  /** The bank for a worker, oldest first. Never null; unknown workers get an empty bank. */
  bank(id: string): Bank { return this.banks.get(id) ?? []; }

  /**
   * Drop banks for workers that have left the registry, so a long operator session
   * does not accumulate lamp banks for every worker ever spawned.
   */
  prune(liveIds: Iterable<string>, ttlMs = 60_000, now = Date.now()): void {
    const live = new Set(liveIds);
    for (const [id, bank] of this.banks) {
      if (live.has(id)) continue;
      const newest = bank[bank.length - 1];
      if (!newest || now - newest.at > ttlMs) this.banks.delete(id);
    }
  }

  clear(): void { this.banks.clear(); }
}

/**
 * Deterministic blink phase, 0..1, advanced by clamped wall-clock deltas.
 *
 * A phase of 0 is "lamps on". Advancing is a pure function of the deltas passed in,
 * so tests can pin an exact phase and get byte-identical output.
 */
export class RackClock {
  phase = 0;
  periodMs: number;
  /** -1 means "no baseline yet"; 0 is a legitimate timestamp. */
  private last = -1;

  constructor(periodMs: number = BLINK_PERIOD_MS) { this.periodMs = periodMs; }

  /** Advance to `nowMs`; returns true when the rendered output could have changed. */
  advance(nowMs: number): boolean {
    if (this.last < 0) { this.last = nowMs; return false; }
    const dt = Math.max(0, Math.min(nowMs - this.last, MAX_DT_MS));
    this.last = nowMs;
    const before = this.phase;
    this.phase = (this.phase + dt / this.periodMs) % 1;
    return this.phase !== before;
  }

  reset(): void { this.phase = 0; this.last = -1; }
}

/** Stable per-worker blink offset so a rack of lamps does not strobe in unison. */
export function blinkOffset(id: string): number {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) { h ^= id.charCodeAt(i); h = Math.imul(h, 16777619); }
  return ((h >>> 0) % 1000) / 1000;
}

/** True when a lamp in the blink cycle is lit for `id` at `phase`. */
export function blinkOn(id: string, phase: number): boolean {
  const p = (phase + blinkOffset(id)) % 1;
  return p < 0.5;
}