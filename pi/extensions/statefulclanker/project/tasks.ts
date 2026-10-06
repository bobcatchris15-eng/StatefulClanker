import { existsSync, readdirSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { appendEvent } from '../protocol/events.ts';
import { readJson, writeJsonAtomic } from '../protocol/persistence.ts';
import type { Task, TaskStatus } from '../protocol/types.ts';
import { ensureLayout } from './paths.ts';

const BUCKETS = ['active', 'complete', 'cancelled'] as const;

function bucketFor(s: TaskStatus): (typeof BUCKETS)[number] {
  if (s === 'complete' || s === 'failed') return 'complete';
  if (s === 'cancelled') return 'cancelled';
  return 'active';
}

function taskFile(root: string, bucket: string, id: string): string {
  return join(ensureLayout(root), 'tasks', bucket, `${id}.json`);
}

function nextId(root: string): string {
  let max = 0;
  for (const b of BUCKETS) {
    for (const f of readdirSync(join(ensureLayout(root), 'tasks', b))) {
      const m = /^t-(\d+)\.json$/.exec(f);
      if (m) max = Math.max(max, parseInt(m[1]!, 10));
    }
  }
  return `t-${String(max + 1).padStart(4, '0')}`;
}

export function createTask(root: string, p: Partial<Task> & { title: string; objective: string }): Task {
  const now = new Date().toISOString();
  const t: Task = {
    id: nextId(root),
    status: 'pending',
    created_by: 'orchestrator',
    assigned_worker: null,
    scope: { files: [], subsystem: '', worktree: '' },
    dependencies: [], related_tasks: [], context_hints: [], constraints: [],
    expected_outputs: [], verification_expectations: [], results: [], evidence: [], unresolved: [],
    ...p,
    created_at: now,
    updated_at: now,
  };
  writeJsonAtomic(taskFile(root, bucketFor(t.status), t.id), t);
  appendEvent(root, 'task.created', { id: t.id });
  return t;
}

export function getTask(root: string, id: string): Task | null {
  for (const b of BUCKETS) {
    const f = taskFile(root, b, id);
    if (existsSync(f)) return readJson<Task>(f, null as never);
  }
  return null;
}

export function updateTask(root: string, id: string, patch: Partial<Task>): Task {
  const cur = getTask(root, id);
  if (!cur) throw new Error(`task not found: ${id}`);
  const next: Task = { ...cur, ...patch, id, updated_at: new Date().toISOString() };
  const nb = bucketFor(next.status);
  writeJsonAtomic(taskFile(root, nb, id), next);
  for (const b of BUCKETS) {
    if (b !== nb) {
      const f = taskFile(root, b, id);
      if (existsSync(f)) unlinkSync(f);
    }
  }
  appendEvent(root, 'task.updated', { id, status: next.status });
  return next;
}

export function listTasks(root: string, filter: { status?: TaskStatus } = {}): Task[] {
  const out: Task[] = [];
  for (const b of BUCKETS) {
    const d = join(ensureLayout(root), 'tasks', b);
    for (const f of readdirSync(d)) if (f.endsWith('.json')) out.push(readJson<Task>(join(d, f), null as never));
  }
  out.sort((a, b) => a.id.localeCompare(b.id));
  return filter.status ? out.filter((t) => t.status === filter.status) : out;
}
