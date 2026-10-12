import { join } from 'node:path';
import { mkdirSync, rmSync } from 'node:fs';
import { appendEvent } from '../protocol/events.ts';
import { readJson, writeJsonAtomic } from '../protocol/persistence.ts';
import type { Worker } from '../protocol/types.ts';
import { ensureLayout } from '../project/paths.ts';

interface Registry { next: number; workers: Record<string, Worker>; reservations?: Record<string, number> }
const sleep = new Int32Array(new SharedArrayBuffer(4));
function withRegistryLock<T>(root: string, fn: () => T): T {
  const path = join(ensureLayout(root), 'workers', '.registry-lock');
  for (let i = 0; i < 100; i++) {
    try {
      mkdirSync(path);
      try { return fn(); } finally { rmSync(path, { recursive: true, force: true }); }
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
      Atomics.wait(sleep, 0, 0, 20);
    }
  }
  throw Error('worker registry busy (stale lock requires operator recovery)');
}


function regFile(root: string): string { return join(ensureLayout(root), 'workers', 'registry.json'); }
function load(root: string): Registry { return readJson<Registry>(regFile(root), { next: 1, workers: {} }); }

/** Reserve capacity before asynchronous spawn; simultaneous spawn calls cannot exceed the cap. */
export function reserveWorkerId(root: string, capacity = 3): string {
  return withRegistryLock(root, () => {
    const r = load(root), now = Date.now();
    const reservations = Object.fromEntries(Object.entries(r.reservations ?? {})
      .filter(([, timestamp]) => now - timestamp < 120000));
    const active = Object.values(r.workers).filter(w =>
      !['COMPLETE', 'CANCELLED', 'FAILED', 'LOST'].includes(w.status)).length;
    if (active + Object.keys(reservations).length >= capacity)
      throw Error('active child worker capacity reached (' + capacity + ')');
    const id = `W${String(r.next).padStart(2, '0')}`;
    r.next++;
    r.reservations = { ...reservations, [id]: now };
    writeJsonAtomic(regFile(root), r);
    return id;
  });
}
export function allocateWorkerId(root: string): string { return reserveWorkerId(root); }
export function releaseWorkerReservation(root: string, id: string): void {
  withRegistryLock(root, () => {
    const r = load(root);
    if (r.reservations?.[id] !== undefined) {
      delete r.reservations[id];
      writeJsonAtomic(regFile(root), r);
    }
  });
}

export function upsertWorker(root: string, w: Worker): Worker {
  return withRegistryLock(root, () => {
    const r = load(root);
    const existed = w.id in r.workers;
    r.workers[w.id] = w;
    if (r.reservations) delete r.reservations[w.id];
    writeJsonAtomic(regFile(root), r);
    appendEvent(root, existed ? 'worker.updated' : 'worker.registered', { id: w.id, status: w.status });
    return w;
  });
}

export function getWorker(root: string, id: string): Worker | null {
  return load(root).workers[id] ?? null;
}

export function listWorkers(root: string): Worker[] {
  return Object.values(load(root).workers).sort((a, b) => a.id.localeCompare(b.id));
}

export function archiveWorker(root: string, id: string): Worker | null {
  return withRegistryLock(root, () => {
    const r = load(root);
    const w = r.workers[id];
    if (!w) return null;
    delete r.workers[id];
    if (r.reservations) delete r.reservations[id];
    writeJsonAtomic(regFile(root), r);
    writeJsonAtomic(join(ensureLayout(root), 'workers', 'history', `${id}.json`), w);
    appendEvent(root, 'worker.archived', { id });
    return w;
  });
}
