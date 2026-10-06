import { EventEmitter } from 'node:events';
import { join } from 'node:path';
import { appendEvent } from '../protocol/events.ts';
import { writeJsonAtomic } from '../protocol/persistence.ts';
import type { Worker, WorkerResult } from '../protocol/types.ts';
import { ensureLayout } from '../project/paths.ts';
import { createTask, updateTask } from '../project/tasks.ts';
import { createWorktree } from '../worktrees/create.ts';
import type { AbilityRequest } from '../catalog/types.ts';
import { allocateWorkerId, archiveWorker, getWorker, listWorkers, upsertWorker } from './registry.ts';
import { PiRpcRuntime } from './runtime.ts';
import type { CatalogService } from '../catalog/service.ts';
import { deriveStatus, initialStatus, type StatusState } from './status.ts';

export interface SpawnSpec {
  taskId: string; role: string; provider: string; model: string; assignment: string;
  /** Pre-allocated id (see allocateId); allocated here when absent. */
  workerId?: string; thinking?: string; abilityProfile?: string;
  lease?: { lease_id: string; expires_at: number } | null;
  worktree?: { path: string; branch: string; base_commit: string };
  extensionPath: string; piCommand: string; args?: string[]; env?: Record<string, string>;
}
export interface ManagerOpts { hangMs?: number; activityThrottleMs?: number; superviseEveryMs?: number; catalog?: CatalogService }

interface Entry { rt: PiRpcRuntime; st: StatusState; lastEvent: number; lastActEmit: number; waiting: boolean; retired: boolean; modelKey: string; startedMs: number; retrySeen: boolean; released: boolean; timer?: NodeJS.Timeout }

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

  allocateId(): string { return allocateWorkerId(this.root); }

  /** Release the worker's lease(s); idempotent. Never throws. */
  private release(id: string, e?: Entry): void {
    if (e) { if (e.released) return; e.released = true; }
    try { this.opts.catalog?.releaseWorker(id); } catch { /* best effort */ }
  }
  private report(id: string, e: Entry, outcome: any, extra: { latency_ms?: number } = {}): void {
    try { this.opts.catalog?.reportOutcome(e.modelKey, outcome, { worker_id: id, ...extra }); } catch { /* best effort */ }
  }

  async spawn(spec: SpawnSpec): Promise<string> {
    const id = spec.workerId ?? allocateWorkerId(this.root);
    const now = new Date().toISOString();
    const cwd = spec.worktree?.path ?? this.root;
    const prior = getWorker(this.root, id)?.display_name;
    const w: Worker = {
      id, ...(prior ? { display_name: prior } : {}), task_id: spec.taskId, role: spec.role, ability_profile: spec.abilityProfile ?? spec.role, provider: spec.provider, model: spec.model,
      endpoint_lease: spec.lease ? { endpoint_id: `${spec.provider}/${spec.model}`, worker_id: id, acquired_at: now, expires_at: new Date(spec.lease.expires_at).toISOString() } : null, session_id: null, generation: 1, pid: null, status: 'STARTING', project_root: this.root,
      worktree: spec.worktree ?? null, started_at: now, last_activity: now, current_action: '', current_tool: '',
      context_usage: { tokens_used: 0, context_window: 0, percentage: 0, compactions: 0 },
      collaboration: { team_ids: [], inbox_cursor: 0, unread_count: 0 }, results: [],
    };
    upsertWorker(this.root, w);
    const rt = new PiRpcRuntime();
    const e: Entry = { rt, st: { ...initialStatus }, lastEvent: Date.now(), lastActEmit: 0, waiting: false, retired: false,
      modelKey: `${spec.provider}/${spec.model}`, startedMs: Date.now(), retrySeen: false, released: false };
    this.runtimes.set(id, e);
    rt.on('event', (ev) => this.onEvent(id, e, ev));
    rt.on('signal', (sig: any) => this.onSignal(id, e, sig));
    rt.on('sc', (payload) => this.onSc(id, e, payload));
    rt.on('exit', (x) => this.onExit(id, e, x));
    rt.start({ piCommand: spec.piCommand, args: spec.args, cwd, env: spec.env, provider: spec.provider, model: spec.model, thinking: spec.thinking,
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
      this.release(id, e);
    }
    return id;
  }

  private setStatus(id: string, e: Entry, next: StatusState): void {
    const changed = next.status !== e.st.status || next.current_tool !== e.st.current_tool;
    e.st = next;
    if (changed) this.patch(id, { status: next.status, current_tool: next.current_tool, last_activity: new Date().toISOString() });
  }

  /** Provider-error signal (rate limit / auth / timeout / malformed). auto_retry_end and the following agent_end are one failure. */
  private onSignal(id: string, e: Entry, sig: { outcome: string; source: string }): void {
    if (sig.source === 'agent_end' && e.retrySeen) return;
    if (sig.source === 'retry') e.retrySeen = true;
    this.report(id, e, sig.outcome);
    appendEvent(this.root, 'worker.provider_error', { id, model: e.modelKey, outcome: sig.outcome });
  }

  private onEvent(id: string, e: Entry, ev: any): void {
    e.lastEvent = Date.now(); e.waiting = false;
    if (ev.type === 'agent_start') e.retrySeen = false;
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
    if (p?.kind === 'name') {
      const cur = getWorker(this.root, id);
      if (!cur || cur.display_name) return;
      const taken = listWorkers(this.root).filter((x) => x.id !== id && x.display_name && !['COMPLETE', 'CANCELLED', 'FAILED', 'LOST'].includes(x.status)).map((x) => x.display_name!);
      const nm = uniqueName(sanitizeName(p.name), taken);
      if (!nm) return;
      upsertWorker(this.root, { ...cur, display_name: nm });
      appendEvent(this.root, 'worker.named', { id, name: nm });
      this.em.emit('named', id, nm);
      return;
    }
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
    const eE = this.runtimes.get(id);
    if (eE) { this.report(id, eE, 'success', { latency_ms: Date.now() - eE.startedMs }); this.release(id, eE); }
    this.em.emit('result', id, result, file);
  }

  private onExit(id: string, e: Entry, x: { code: number | null; expected?: boolean }): void {
    if (e.timer) clearInterval(e.timer);
    const prev = e.st.status;
    this.setStatus(id, e, deriveStatus(e.st, { type: 'exit', code: x.code }));
    if (e.st.status === 'LOST' && prev !== 'LOST' && !e.retired) {
      appendEvent(this.root, 'worker.failed', { id, code: x.code, reason: 'process exited' });
    }
    this.release(id, e);
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
    this.release(id, e);
  }

  async retire(id: string): Promise<void> {
    const e = this.runtimes.get(id);
    if (e) {
      e.retired = true;
      if (e.timer) clearInterval(e.timer);
      await e.rt.stop();
      this.release(id, e);
      this.runtimes.delete(id);
    } else this.release(id);
    archiveWorker(this.root, id);
  }

  /** Release every live worker's lease (parent session shutdown). */
  releaseAll(): void { for (const [id, e] of this.runtimes) this.release(id, e); }

  recover(): string[] {
    try { this.opts.catalog?.recover(); } catch { /* best effort */ }
    const lost: string[] = [];
    for (const w of listWorkers(this.root)) {
      if (['COMPLETE', 'CANCELLED', 'FAILED', 'LOST'].includes(w.status)) continue;
      if (this.runtimes.has(w.id)) continue;
      if (w.pid && alive(w.pid)) continue;
      upsertWorker(this.root, { ...w, status: 'LOST' });
      this.release(w.id);
      appendEvent(this.root, 'worker.failed', { id: w.id, reason: 'pid not alive' });
      lost.push(w.id);
    }
    return lost;
  }
}

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch (e) { return (e as NodeJS.ErrnoException).code === 'EPERM'; }
}

export interface SpawnParams {
  assignment: string; model?: string; ability_profile?: string;
  requirements?: { min?: Record<string, string>; weights?: Record<string, number>; min_context?: number };
  preferences?: { free_only?: boolean; prefer_provider?: string[]; avoid_provider?: string[]; diversity_from?: string[] };
  relationship?: { independent?: boolean; independent_of?: string };
  dry_run?: boolean; role?: string; task_title?: string; files?: string[]; worktree_required?: boolean;
  expected_outputs?: string[]; context_hints?: string[];
}
export interface SpawnLaunch { extensionPath: string; piCommand: string; args?: string[]; env?: Record<string, string> }

/** Trim, strip control chars/newlines/brackets, cap 20 chars. Returns '' when nothing usable. */
export function sanitizeName(raw: unknown): string {
  return String(raw ?? '').replace(/[\u0000-\u001f\u007f\[\]{}()<>]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 20).trim();
}

/** Case-insensitive dedupe against taken names by suffixing -2, -3 (result stays <=20 chars). */
export function uniqueName(name: string, taken: string[]): string {
  if (!name) return '';
  const low = new Set(taken.map((t) => t.toLowerCase()));
  if (!low.has(name.toLowerCase())) return name;
  for (let n = 2; ; n++) {
    const suf = `-${n}`;
    const cand = name.slice(0, 20 - suf.length).trimEnd() + suf;
    if (!low.has(cand.toLowerCase())) return cand;
  }
}

export function slugify(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || 'task';
}

export function buildRequest(p: SpawnParams, parentKey: string | undefined): AbilityRequest {
  const rq = p.requirements ?? {}, pf = p.preferences ?? {}, rel = p.relationship ?? {};
  const req: AbilityRequest = { profile: p.ability_profile ?? 'implementation' };
  if (rq.min) req.min = rq.min as any;
  if (rq.weights) req.weights = rq.weights as any;
  if (rq.min_context !== undefined) req.min_context = rq.min_context;
  if (pf.free_only) req.free_only = true;
  if (pf.prefer_provider) req.prefer_provider = pf.prefer_provider;
  if (pf.avoid_provider) req.avoid_provider = pf.avoid_provider;
  if (pf.diversity_from) req.diversity_from = pf.diversity_from;
  if (rel.independent_of) req.independent_of = rel.independent_of;
  else if (rel.independent && parentKey) req.independent_of = parentKey;
  return req;
}

/**
 * Select (never inheriting the parent model), claim lease, create task+worktree keyed by the pre-allocated
 * worker id, write receipts/spawn/<id>.json, spawn. dry_run returns the ranking and spawns nothing.
 */
export async function spawnSelected(mgr: WorkerManager, catalog: CatalogService, root: string, p: SpawnParams, launch: SpawnLaunch):
  Promise<{ ok: boolean; error?: string; dry_run?: boolean; selection?: any; worker_id?: string; model?: string; worktree?: string | null; task_id?: string; receipt?: string }> {
  const parentKey = catalog.parentModelKey();
  const request = buildRequest(p, parentKey);
  const sel = catalog.resolve(request, { explicit: p.model });
  if (p.dry_run) return { ok: sel.ok, dry_run: true, selection: sel, error: sel.error };
  if (!sel.ok || !sel.chosen) return { ok: false, error: sel.error ?? sel.reason, selection: sel };
  const chosen = sel.chosen;
  const id = mgr.allocateId();
  const lease = catalog.claimLease(chosen.key, id);
  if (!lease) return { ok: false, error: `lease unavailable for ${chosen.key}`, selection: sel };
  try {
    const task = createTask(root, {
      title: p.task_title ?? p.assignment.slice(0, 60), objective: p.assignment, status: 'active',
      scope: { files: p.files ?? [], subsystem: '', worktree: '' },
      expected_outputs: p.expected_outputs ?? [], context_hints: p.context_hints ?? [],
    });
    const worktree = p.worktree_required === false ? undefined : createWorktree(root, id, slugify(p.task_title ?? p.assignment));
    const receipt = join(ensureLayout(root), 'receipts', 'spawn', `${id}.json`);
    writeJsonAtomic(receipt, { worker_id: id, task_id: task.id, request: { ...p, assignment: undefined, resolved: request },
      selection: sel, lease, parent_model: parentKey ?? null });
    await mgr.spawn({
      workerId: id, taskId: task.id, role: p.role ?? 'worker', abilityProfile: request.profile, provider: chosen.provider, model: chosen.id,
      thinking: chosen.thinking ?? 'off', lease, assignment: p.assignment, worktree, ...launch,
    });
    updateTask(root, task.id, { assigned_worker: id, scope: { ...task.scope, worktree: worktree?.path ?? '' } });
    return { ok: true, worker_id: id, model: chosen.key, worktree: worktree?.path ?? null, task_id: task.id, receipt, selection: { reason: sel.reason } };
  } catch (e) {
    try { catalog.releaseWorker(id); } catch { /* */ }
    return { ok: false, error: `spawn failed: ${(e as Error).message}` };
  }
}
