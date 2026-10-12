/**
 * Shared child-process runner for external pools.
 *
 * Adapters (`pools/opencode/`, `pools/agy/`) supply argv and a `normalize` function that turns one
 * raw CLI line into {@link PoolEvent}s. The runner owns the process lifecycle every pool shares:
 * line-buffered output, append-only logging, timeout, tree-kill cancellation and a single terminal
 * result. Guarantees:
 *
 * - `on` listeners may be attached before or after exit; terminal events are replayed once to late
 *   subscribers (see `PoolWorker` implementations, which buffer the terminal event).
 * - `done()` resolves exactly once, even for spawn failures (`ENOENT` -> code 1, `error` set).
 * - `cancel()` is idempotent and safe after exit.
 */
import { spawn, type ChildProcess } from 'node:child_process';
import { createWriteStream, mkdirSync, type WriteStream } from 'node:fs';
import { dirname } from 'node:path';
import type { PoolEvent, PoolEventListener } from './types.ts';

export interface PoolRunResult {
  code: number | null;
  signal: string | null;
  timedOut: boolean;
  cancelled: boolean;
  error?: string;
}

export interface PoolRunOptions {
  command: string;
  args: string[];
  cwd: string;
  env?: Record<string, string | undefined>;
  /** Absolute path of the append-only raw log. Parent directories are created. */
  logPath: string;
  /** Milliseconds before the run is killed; `0`/omitted disables the timeout. */
  timeoutMs?: number;
  /** Extra kill grace after SIGTERM before SIGKILL, in ms. Default 3000. */
  killGraceMs?: number;
  /** Turn one raw output line into normalized events. */
  normalize: (line: string, stream: 'stdout' | 'stderr') => PoolEvent[];
}

export interface PoolRunHandle {
  readonly pid: number | null;
  on(listener: PoolEventListener): () => void;
  cancel(reason?: string): Promise<void>;
  done(): Promise<PoolRunResult>;
}

/** Split a stream into lines, flushing a trailing partial line on end. */
function attachLines(stream: NodeJS.ReadableStream, onLine: (line: string) => void): void {
  let buf = '';
  stream.on('data', (chunk: Buffer | string) => {
    buf += chunk.toString();
    let idx = buf.indexOf('\n');
    while (idx >= 0) {
      const line = buf.slice(0, idx).replace(/\r$/, '');
      buf = buf.slice(idx + 1);
      onLine(line);
      idx = buf.indexOf('\n');
    }
  });
  stream.on('end', () => {
    if (buf.length) onLine(buf.replace(/\r$/, ''));
  });
}

function killTree(child: ChildProcess, graceMs: number): void {
  if (child.pid === undefined || child.pid === null) return;
  if (process.platform === 'win32') {
    try {
      spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    } catch {
      try { child.kill(); } catch { /* gone */ }
    }
    return;
  }
  try { child.kill('SIGTERM'); } catch { /* gone */ }
  const t = setTimeout(() => {
    try { child.kill('SIGKILL'); } catch { /* gone */ }
  }, Math.max(0, graceMs));
  if (typeof t.unref === 'function') t.unref();
}

export function runExternal(opts: PoolRunOptions): PoolRunHandle {
  const listeners = new Set<PoolEventListener>();
  const emit = (event: PoolEvent): void => {
    for (const l of [...listeners]) {
      try { l(event); } catch { /* listener errors must not break the runner */ }
    }
  };

  let log: WriteStream | null = null;
  try {
    mkdirSync(dirname(opts.logPath), { recursive: true });
    log = createWriteStream(opts.logPath, { flags: 'a' });
    log.on('error', () => { /* logging is best-effort */ });
  } catch {
    log = null;
  }

  let child: ChildProcess | null = null;
  let finished = false;
  let cancelled = false;
  let timedOut = false;
  let spawnError: string | undefined;
  let timer: NodeJS.Timeout | null = null;

  let resolveDone!: (r: PoolRunResult) => void;
  const donePromise = new Promise<PoolRunResult>((resolve) => { resolveDone = resolve; });

  const finalize = (code: number | null, signal: string | null): void => {
    if (finished) return;
    finished = true;
    if (timer) { clearTimeout(timer); timer = null; }
    const result: PoolRunResult = { code, signal, timedOut, cancelled, error: spawnError };
    emit({ type: 'exit', code, signal, timedOut, cancelled });
    if (log) {
      try { log.end(); } catch { /* ignore */ }
      log = null;
    }
    resolveDone(result);
  };

  const handleLine = (line: string, stream: 'stdout' | 'stderr'): void => {
    if (log) {
      try { log.write(line + '\n'); } catch { /* ignore */ }
    }
    let events: PoolEvent[] = [];
    try { events = opts.normalize(line, stream); } catch { events = []; }
    for (const ev of events) emit(ev);
  };

  try {
    child = spawn(opts.command, opts.args, {
      cwd: opts.cwd,
      env: { ...process.env, ...(opts.env ?? {}) },
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
  } catch (e) {
    spawnError = e instanceof Error ? e.message : String(e);
    finalize(1, null);
    return {
      get pid() { return null; },
      on(listener) { listeners.add(listener); return () => listeners.delete(listener); },
      async cancel() { /* nothing to kill */ },
      done: () => donePromise,
    };
  }

  attachLines(child.stdout!, (l) => handleLine(l, 'stdout'));
  attachLines(child.stderr!, (l) => handleLine(l, 'stderr'));

  child.on('error', (e) => {
    spawnError = e.message;
    finalize(1, null);
  });
  child.on('exit', (code, signal) => finalize(code, signal));

  const timeoutMs = opts.timeoutMs ?? 0;
  if (timeoutMs > 0) {
    timer = setTimeout(() => {
      timedOut = true;
      emit({ type: 'progress', line: `[timeout] killing after ${timeoutMs}ms` });
      if (child) killTree(child, opts.killGraceMs ?? 3000);
    }, timeoutMs);
    if (typeof timer.unref === 'function') timer.unref();
  }

  return {
    get pid() { return child?.pid ?? null; },
    on(listener) { listeners.add(listener); return () => { listeners.delete(listener); }; },
    async cancel() {
      if (finished) return;
      cancelled = true;
      if (child) killTree(child, opts.killGraceMs ?? 3000);
      await donePromise;
    },
    done: () => donePromise,
  };
}
