import { join } from 'node:path';
import { appendEvent } from '../protocol/events.ts';
import { readJson, writeJsonAtomic } from '../protocol/persistence.ts';
import type { Worker } from '../protocol/types.ts';
import { ensureLayout } from '../project/paths.ts';

interface Registry { next: number; workers: Record<string, Worker> }

function regFile(root: string): string { return join(ensureLayout(root), 'workers', 'registry.json'); }
function load(root: string): Registry { return readJson<Registry>(regFile(root), { next: 1, workers: {} }); }

export function allocateWorkerId(root: string): string {
  const r = load(root);
  const id = `W${String(r.next).padStart(2, '0')}`;
  r.next += 1;
  writeJsonAtomic(regFile(root), r);
  return id;
}

export function upsertWorker(root: string, w: Worker): Worker {
  const r = load(root);
  const existed = w.id in r.workers;
  r.workers[w.id] = w;
  writeJsonAtomic(regFile(root), r);
  appendEvent(root, existed ? 'worker.updated' : 'worker.registered', { id: w.id, status: w.status });
  return w;
}

export function getWorker(root: string, id: string): Worker | null {
  return load(root).workers[id] ?? null;
}

export function listWorkers(root: string): Worker[] {
  return Object.values(load(root).workers).sort((a, b) => a.id.localeCompare(b.id));
}

export function archiveWorker(root: string, id: string): Worker | null {
  const r = load(root);
  const w = r.workers[id];
  if (!w) return null;
  delete r.workers[id];
  writeJsonAtomic(regFile(root), r);
  writeJsonAtomic(join(ensureLayout(root), 'workers', 'history', `${id}.json`), w);
  appendEvent(root, 'worker.archived', { id });
  return w;
}
