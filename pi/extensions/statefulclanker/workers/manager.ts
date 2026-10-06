import { EventEmitter } from 'node:events';
import { join } from 'node:path';
import { appendEvent } from '../protocol/events.ts';
import { writeJsonAtomic } from '../protocol/persistence.ts';
import type { Worker, WorkerResult } from '../protocol/types.ts';
import { ensureLayout } from '../project/paths.ts';
import { allocateWorkerId, archiveWorker, getWorker, listWorkers, upsertWorker } from './registry.ts';
import { PiRpcRuntime } from './runtime.ts';
import { deriveStatus, initialStatus, type StatusState } from './status.ts';

export interface SpawnSpec {
  taskId: string; role: string; provider: string; model: string; assignment: string;
  worktree?: { path: string; branch: string; base_commit: string };
  extensionPath: string; piCommand: string; args?: string[]; env?: Record<string, string>;
}
export interface ManagerOpts { hangMs?: number; activityThrottleMs?: number; superviseEveryMs?: number }

interface Entry { rt: PiRpcRuntime; st: StatusState; lastEvent: number; lastActEmit: number; waiting: boolean; retired: boolean; timer?: NodeJS.Timeout }

export class WorkerManager {
  private em = new EventEmitter();
  private runtimes = new Map<string, Entry>();
  private root: string;
  private opts: ManagerOpts;
  constructor(root: string, opts: ManagerOpts = {}) { this.root = root; this.opts = opts; }

  on(ev: string, cb: (...a: any[]) => void): this { this.em.on(ev, cb); return this; }
  runtime(id: string): PiRpcRuntime | undefined { return this.runtimes.get(id)?.rt; }

  private patch(id: string, p: Partial<Worker>): void {
    const w = getWorker(this.root, id);
    if (w) upsertWorker(this.root, { ...w, ...p });
  }

  async spawn(spec: SpawnSpec): Promise<string> {
    const id = allocateWorkerId(this.root);
    const now = new Date().toISOString();
    const cwd = spec.worktree?.path ?? this.root;
    const w: Worker = {
      id, task_id: spec.taskId, role: spec.role, ability_profile: spec.role, provider: spec.provider, model: spec.model,
      endpoint_lease: null, session_id: null, generation: 1, pid: null, status: 'STARTING', project_root: this.root,
      worktree: spec.worktree ?? null, started_at: now, last_activity: now, current_action: '', current_tool: '',
      context_usage: { tokens_used: 0, context_window: 0, percentage: 0, compactions: 0 },
      collaboration: { team_ids: [], inbox_cursor: 0, unread_count: 0 }, results: [],
    };
    upsertWorker(this.root, w);
    const rt = new PiRpcRuntime();
    const e: Entry = { rt, st: { ...initialStatus }, lastEvent: Date.now(), lastActEmit: 0, waiting: false, retired: false };
    this.runtimes.set(id, e);
    rt.on('event', (ev) => this.onEvent(id, e, ev));
    rt.on('sc', (payload) => this.onSc(id, e, payload));
    rt.on('exit', (x) => this.onExit(id, e, x));
    rt.start({ piCommand: spec.piCommand, args: spec.args, cwd, env: spec.env, provider: spec.provider, model: spec.model,
      extensionPath: spec.extensionPath, workerId: id, projectRoot: this.root, taskId: spec.taskId });
    this.patch(id, { pid: rt.pid });
    appendEvent(this.root, 'worker.started', { id, task_id: spec.taskId, pid: rt.pid });
    const hang = this.opts.hangMs;
    if (hang) {
      e.timer = setInterval(() => {
        if (!e.waiting && !e.retired && Date.now() - e.lastEvent > hang && e.st.status !== 'COMPLETE') {
          e.waiting = true;
          appendEvent(this.root, 'worker.waiting', { id, idle_ms: Date.now() - e.lastEvent });
        }
      }, this.opts.superviseEveryMs ?? Math.max(50, Math.floor(hang / 2)));
      e.timer.unref();
    }
    try { await rt.prompt(spec.assignment); } catch (err) {
      appendEvent(this.root, 'worker.failed', { id, error: String((err as Error).message) });
      this.patch(id, { status: 'FAILED' });
    }
    return id;
  }

  private setStatus(id: string, e: Entry, next: StatusState): void {
    const changed = next.status !== e.st.status || next.current_tool !== e.st.current_tool;
    e.st = next;
    if (changed) this.patch(id, { status: next.status, current_tool: next.current_tool, last_activity: new Date().toISOString() });
  }

  private onEvent(id: string, e: Entry, ev: any): void {
    e.lastEvent = Date.now(); e.waiting = false;
    this.setStatus(id, e, deriveStatus(e.st, ev));
    const throttle = this.opts.activityThrottleMs ?? 2000;
    if (ev.type === 'tool_execution_start' || ev.type === 'turn_end' || ev.type === 'agent_end') {
      if (Date.now() - e.lastActEmit >= throttle) {
        e.lastActEmit = Date.now();
        appendEvent(this.root, 'worker.activity', { id, type: ev.type, tool: ev.toolName ?? '' });
      }
    }
    this.em.emit('event', id, ev);
  }

  private onSc(id: string, e: Entry, p: any): void {
    e.lastEvent = Date.now(); e.waiting = false;
    this.setStatus(id, e, deriveStatus(e.st, { type: 'sc', payload: p }));
    if (p?.kind === 'progress') {
      this.patch(id, { current_action: String(p.action ?? p.summary ?? '') });
      return;
    }
    if (p?.kind !== 'finish') return;
    const w = getWorker(this.root, id);
    const result: WorkerResult = {
      worker_id: id, task_id: w?.task_id ?? '', status: String(p.status ?? 'complete'), summary: String(p.summary ?? ''),
      changed_files: p.changed_files ?? [], artifacts: p.artifacts ?? [], tests_added: p.tests_added ?? [], tests_run: p.tests_run ?? [],
      test_results: p.test_results ?? [], important_discoveries: p.important_discoveries ?? [], lessons_written: p.lessons_written ?? [],
      unresolved_questions: p.unresolved_questions ?? [], known_risks: p.known_risks ?? [], collaboration_packets: p.collaboration_packets ?? [],
      confidence: p.confidence ?? '',
    };
    const ts = new Date().toISOString().replace(/[:.]/g, '-');
    const file = join(ensureLayout(this.root), 'receipts', 'workers', `${id}-${ts}.json`);
    writeJsonAtomic(file, result);
    if (w) upsertWorker(this.root, { ...w, status: 'COMPLETE', current_tool: '', results: [...w.results, result] });
    appendEvent(this.root, 'worker.completed', { id, receipt: file });
    this.em.emit('result', id, result, file);
  }

  private onExit(id: string, e: Entry, x: { code: number | null; expected?: boolean }): void {
    if (e.timer) clearInterval(e.timer);
    const prev = e.st.status;
    this.setStatus(id, e, deriveStatus(e.st, { type: 'exit', code: x.code }));
    if (e.st.status === 'LOST' && prev !== 'LOST' && !e.retired) {
      appendEvent(this.root, 'worker.failed', { id, code: x.code, reason: 'process exited' });
    }
    this.em.emit('exit', id, x);
  }

  private need(id: string): Entry {
    const e = this.runtimes.get(id);
    if (!e) throw new Error(`no runtime for ${id}`);
    return e;
  }
  message(id: string, text: string): Promise<any> { return this.need(id).rt.steer(text); }
  followUp(id: string, text: string): Promise<any> { return this.need(id).rt.followUp(text); }

  async cancel(id: string): Promise<void> {
    const e = this.need(id);
    try { await e.rt.abort(); } catch { /* */ }
    e.st = { ...e.st, status: 'CANCELLED', current_tool: '' };
    this.patch(id, { status: 'CANCELLED', current_tool: '' });
    appendEvent(this.root, 'worker.cancelled', { id });
  }

  async retire(id: string): Promise<void> {
    const e = this.runtimes.get(id);
    if (e) {
      e.retired = true;
      if (e.timer) clearInterval(e.timer);
      await e.rt.stop();
      this.runtimes.delete(id);
    }
    archiveWorker(this.root, id);
  }

  recover(): string[] {
    const lost: string[] = [];
    for (const w of listWorkers(this.root)) {
      if (['COMPLETE', 'CANCELLED', 'FAILED', 'LOST'].includes(w.status)) continue;
      if (this.runtimes.has(w.id)) continue;
      if (w.pid && alive(w.pid)) continue;
      upsertWorker(this.root, { ...w, status: 'LOST' });
      appendEvent(this.root, 'worker.failed', { id: w.id, reason: 'pid not alive' });
      lost.push(w.id);
    }
    return lost;
  }
}

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch (e) { return (e as NodeJS.ErrnoException).code === 'EPERM'; }
}
