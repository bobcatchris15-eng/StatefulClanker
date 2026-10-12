/**
 * Liveness for pane data that is polled from disk.
 *
 * A supervisor pane is a *cached snapshot* plus a timer that re-reads it. Both parts fail badly:
 * a snapshot that stops refreshing shows long-dead work as RUNNING, and a timer whose body throws
 * dies silently — the widget stays registered, keeps painting the stale snapshot, and nothing
 * indicates the feed is dead. `setInterval` keeps firing after a throw, so the pane limps along
 * half-updated (clock advanced, rows frozen) until the next bad read, which is exactly the
 * "still showing them hours later" symptom.
 *
 * RowSource makes the *render* path the source of truth: any paint re-reads if the snapshot has
 * aged out, so a dead timer degrades to "painted on demand" instead of "frozen". The timer is
 * then only an optimization for when nothing is painting, and is written so it cannot die.
 */
export interface RowSourceOpts<T> {
  /** Read fresh rows. May throw; throws are captured, never propagated. */
  read: () => T;
  /** Snapshot considered stale after this long. Also the timer period. Default 500ms. */
  everyMs?: number;
  /** Called for each captured read failure. */
  onError?: (err: unknown) => void;
}

export class RowSource<T> {
  /** Last successful read, or null before the first one succeeds. */
  rows: T | null = null;
  /** When `rows` was last refreshed successfully (0 = never). */
  updatedAt = 0;
  /** Consecutive failed reads; reset to 0 by a success. */
  failures = 0;
  /** Last captured read error, cleared by a success. */
  lastError: unknown = null;

  private timer: NodeJS.Timeout | null = null;
  private readonly opts: RowSourceOpts<T>;
  private readonly everyMs: number;

  constructor(opts: RowSourceOpts<T>) {
    this.opts = opts;
    this.everyMs = opts.everyMs ?? 500;
  }

  /** True when the snapshot is older than the poll period. */
  stale(now: number): boolean {
    return this.updatedAt === 0 || now - this.updatedAt >= this.everyMs;
  }

  /**
   * Re-read if the snapshot has aged out. Safe to call from a render path: never throws, and a
   * failed read leaves the previous snapshot in place rather than blanking the pane.
   *
   * @returns true when `rows` was replaced by a successful read.
   */
  ensureFresh(now: number): boolean {
    if (!this.stale(now)) return false;
    return this.refresh(now);
  }

  /** Force a re-read. Never throws. @returns true when `rows` was replaced. */
  refresh(now: number = Date.now()): boolean {
    try {
      this.rows = this.opts.read();
      this.updatedAt = now;
      this.failures = 0;
      this.lastError = null;
      return true;
    } catch (err) {
      this.failures++;
      this.lastError = err;
      try { this.opts.onError?.(err); } catch { /* a bad error handler must not kill the feed */ }
      return false;
    }
  }

  /**
   * Start the background poll. Idempotent. The interval body is wrapped so no failure — from the
   * read, from `onError`, from anything else — can escape and compromise the timer.
   */
  start(now: number = Date.now()): void {
    if (this.timer) return;
    this.ensureFresh(now);
    this.timer = setInterval(() => { try { this.refresh(); } catch { /* refresh is already guarded */ } }, this.everyMs);
    this.timer.unref?.();
  }

  stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = null;
  }

  /** False once stopped; a pane that lost its timer can still paint via ensureFresh. */
  get alive(): boolean {
    return this.timer !== null;
  }
}