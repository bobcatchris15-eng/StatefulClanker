/**
 * Process seams for external pools: default `child_process` spawn, line collection, CLI probing.
 *
 * Erasable TypeScript only.
 */
import { spawn } from 'node:child_process';
import type { ExternalPoolId, PoolAvailability, PoolChild, SpawnFn } from './types.ts';

/** Default spawn using `node:child_process`. Pipes stdout/stderr, ignores stdin. */
export function defaultSpawn(): SpawnFn {
  return (command, args, opts) => {
    const cp = spawn(command, args, {
      cwd: opts.cwd,
      env: opts.env ?? process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    return {
      get pid() {
        return cp.pid;
      },
      get stdout() {
        return cp.stdout;
      },
      get stderr() {
        return cp.stderr;
      },
      onClose(cb) {
        cp.on('close', cb);
      },
      onError(cb) {
        cp.on('error', cb);
      },
      kill(signal) {
        return cp.kill(signal as NodeJS.Signals | undefined);
      },
    } satisfies PoolChild;
  };
}

/**
 * Consume an async byte/string stream as UTF-8 lines and invoke `onLine` per complete line.
 * Handles partial chunks and a trailing line without a newline.
 */
export async function collectLines(
  stream: AsyncIterable<string | Uint8Array> | null,
  onLine: (line: string) => void | Promise<void>,
): Promise<void> {
  if (!stream) return;
  const decoder = new TextDecoder();
  let buf = '';
  for await (const chunk of stream) {
    buf += typeof chunk === 'string' ? chunk : decoder.decode(chunk, { stream: true });
    let idx = buf.indexOf('\n');
    while (idx >= 0) {
      const line = buf.slice(0, idx).replace(/\r$/, '');
      buf = buf.slice(idx + 1);
      if (line.length > 0) await onLine(line);
      idx = buf.indexOf('\n');
    }
  }
  buf += decoder.decode();
  if (buf.trim().length > 0) await onLine(buf);
}

/**
 * Probe a CLI by running `<command> <versionArgs>` and resolving its first stdout line.
 * Never throws: a missing binary, non-zero exit, or timeout resolves `available: false`.
 */
export function probeCli(
  pool: ExternalPoolId,
  command: string,
  versionArgs: string[],
  spawn: SpawnFn,
  opts: { cwd?: string; timeoutMs?: number } = {},
): Promise<PoolAvailability> {
  const timeoutMs = opts.timeoutMs ?? 5000;
  return new Promise<PoolAvailability>((resolve) => {
    let version = '';
    let settled = false;
    const done = (value: PoolAvailability) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    let child: PoolChild;
    try {
      child = spawn(command, versionArgs, { cwd: opts.cwd ?? process.cwd() });
    } catch (err) {
      done({ pool, available: false, command, reason: messageOf(err) });
      return;
    }
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        /* already gone */
      }
      done({ pool, available: false, command, reason: `probe timed out after ${timeoutMs}ms` });
    }, timeoutMs);
    child.onError((err) => done({ pool, available: false, command, reason: messageOf(err) }));
    child.onClose((code) => {
      if (code === 0) done({ pool, available: true, command, version });
      else done({ pool, available: false, command, reason: `exit code ${String(code)}` });
    });
    void collectLines(child.stdout, (line) => {
      if (!version) version = line.trim();
    });
    // Drain stderr so the child cannot block on a full pipe.
    void collectLines(child.stderr, () => {});
  });
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
