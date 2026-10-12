/**
 * Durable, one-file-per-worker persistence for the pool registry.
 *
 * Layout (under `baseDir`, default `.statefulclanker/pools`):
 *   <baseDir>/<id>.json      — latest ExternalWorkerSpec snapshot, written on every transition
 *   <baseDir>/<id>.log       — raw stdout/stderr, appended by the runner
 *
 * One writer (the owning registry instance) per file. `readStale()` is read-only and is used at
 * startup to reconcile records left `queued|starting|running|streaming` by a previous process —
 * their child processes are gone, so they are reclassified `lost`. See [[external-agent-pools]].
 *
 * Erasable TypeScript only.
 */
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import type { ExternalWorkerSpec, PoolWorkerStatus } from './types.ts';

export const ACTIVE_STATUSES: readonly PoolWorkerStatus[] = ['queued', 'starting', 'running', 'streaming'];

export interface PoolStoreOptions {
  baseDir?: string;
  cwd?: string;
}

export class PoolStore {
  readonly baseDir: string;
  private readonly cwd: string;

  constructor(opts: PoolStoreOptions = {}) {
    this.cwd = opts.cwd ?? process.cwd();
    this.baseDir = opts.baseDir ?? join('.statefulclanker', 'pools');
  }

  private abs(rel: string): string {
    return isAbsolute(rel) ? rel : resolve(this.cwd, rel);
  }

  /** Absolute path of the JSON record for `id`. */
  recordPath(id: string): string {
    return this.abs(join(this.baseDir, `${safeFilePart(id)}.json`));
  }

  /** Absolute path of the raw log for `id`. */
  logPath(id: string): string {
    return this.abs(join('.statefulclanker', 'pool-logs', `${safeFilePart(id)}.log`));
  }

  async ensureDirs(): Promise<void> {
    await mkdir(dirname(this.recordPath('x')), { recursive: true });
    await mkdir(dirname(this.logPath('x')), { recursive: true });
  }

  async save(spec: ExternalWorkerSpec): Promise<void> {
    await this.ensureDirs();
    await writeFile(this.recordPath(spec.id), `${JSON.stringify(spec, null, 2)}\n`, 'utf8');
  }

  async get(id: string): Promise<ExternalWorkerSpec | undefined> {
    const path = this.recordPath(id);
    if (!existsSync(path)) return undefined;
    try {
      const raw = await readFile(path, 'utf8');
      return JSON.parse(raw) as ExternalWorkerSpec;
    } catch {
      return undefined;
    }
  }

  async list(): Promise<ExternalWorkerSpec[]> {
    const dir = dirname(this.recordPath('x'));
    if (!existsSync(dir)) return [];
    const entries = await readdir(dir);
    const specs: ExternalWorkerSpec[] = [];
    for (const entry of entries) {
      if (!entry.endsWith('.json')) continue;
      const spec = await this.get(entry.slice(0, -'.json'.length));
      if (spec) specs.push(spec);
    }
    return specs;
  }

  /**
   * Read records whose owning process is gone. Purely a reader: it does not mutate the store;
   * the registry decides the `lost` transition and persists it.
   */
  async readStale(): Promise<ExternalWorkerSpec[]> {
    const specs = await this.list();
    return specs.filter((s) => ACTIVE_STATUSES.includes(s.status));
  }
}

/** Keep ids usable as filenames without silently collapsing distinct ids. */
export function safeFilePart(id: string): string {
  return id.replace(/[^A-Za-z0-9._-]/g, '_');
}
