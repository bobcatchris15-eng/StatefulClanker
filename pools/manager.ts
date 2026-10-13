/**
 * Unified external worker supervisor: OpenCode sessions, agy headless processes, Jules REST sessions.
 * A successful backend turn is submitted for operator verification, not automatically task_verified.
 */
import { randomUUID } from 'node:crypto';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { PoolStore } from './store.ts';
import { OpenCodeServer } from './opencode-server.ts';
import { JulesRest, isJulesTerminal, julesStatus } from './jules-rest.ts';
import { agyAdapter } from './agy.ts';
import { runExternal, type PoolRunHandle } from './runner.ts';
import type { ExternalWorkerSpec, ExternalPoolId, PoolWorkerStatus, PoolEvent } from './types.ts';

const final = new Set<PoolWorkerStatus>(['succeeded','failed','cancelled','timeout','lost']);
export interface ExternalLaunch {
  pool: ExternalPoolId;
  assignment: string;
  model?: string;
  title?: string;
  repo?: string;
  taskId?: string;
  source?: string;
  branch?: string;
  timeoutMs?: number;
  requirePlanApproval?: boolean;
  autoCreatePr?: boolean;
}
export type ExternalView = Pick<ExternalWorkerSpec, 'id' | 'pool' | 'status' | 'externalSessionId' | 'startedAt' | 'endedAt' | 'touchedPaths' | 'note' | 'metadata'>;
type BackendDeps = { openCode?: OpenCodeServer; jules?: JulesRest; store?: PoolStore; now?: () => number; onChange?: (record: ExternalWorkerSpec) => void };

export class ExternalPoolManager {
  private readonly store: PoolStore;
  private readonly opencode: OpenCodeServer;
  private readonly jules: JulesRest;
  private readonly now: () => number;
  private readonly onChange: (s: ExternalWorkerSpec) => void;
  private readonly records = new Map<string, ExternalWorkerSpec>();
  private readonly pendingWrites = new Map<string, Promise<void>>();
  private readonly processes = new Map<string, PoolRunHandle>();
  private ticking = false;
  private timer: NodeJS.Timeout | null = null;
  private lastJulesPoll = 0;
  private readonly root: string;
  constructor(root: string, deps: BackendDeps = {}) {
    this.root = resolve(root);
    this.store = deps.store ?? new PoolStore({ cwd: this.root });
    this.opencode = deps.openCode ?? new OpenCodeServer(this.root);
    this.jules = deps.jules ?? new JulesRest();
    this.now = deps.now ?? Date.now;
    this.onChange = deps.onChange ?? (() => {});
  }
  list(): ExternalWorkerSpec[] {
    return [...this.records.values()].sort((a,b) => (a.startedAt ?? 0) - (b.startedAt ?? 0));
  }
  get(id: string): ExternalWorkerSpec {
    const s = this.records.get(id);
    if (!s) throw new Error('Unknown external worker ' + id);
    return s;
  }
  private async save(s: ExternalWorkerSpec): Promise<void> {
    this.records.set(s.id, s);
    // Serialize writes for the same worker; high-frequency activity updates must not
    // allow a late completion to be overwritten by an earlier, slower JSON write.
    const prior = this.pendingWrites.get(s.id) ?? Promise.resolve();
    const pending = prior.catch(() => {}).then(() => this.store.save(s));
    this.pendingWrites.set(s.id, pending);
    try { await pending; }
    finally {
      if (this.pendingWrites.get(s.id) === pending) this.pendingWrites.delete(s.id);
    }
    // Avoid stale progress frames reaching the task ledger after a terminal result.
    if (this.records.get(s.id) === s) this.onChange(s);
  }
  private async patch(id: string, props: Partial<ExternalWorkerSpec>): Promise<ExternalWorkerSpec> {
    const s = { ...this.get(id), ...props };
    await this.save(s);
    return s;
  }
  async start(): Promise<void> {
    for (const s of await this.store.list()) this.records.set(s.id, s);
    // Remote Jules work continues without the orchestrator. Never mark it LOST on restart.
    // Local agy child processes cannot be trusted to survive an operator restart.
    for (const s of this.list()) {
      if (s.pool === 'agy' && !final.has(s.status)) await this.patch(s.id, { status: 'lost', note: 'Operator restarted; local agy process no longer supervised' });
    }
    this.timer ??= setInterval(() => { void this.refresh().catch(() => {}); }, 2500);
    this.timer.unref?.();
    void this.refresh().catch(() => {});
  }
  async stop(): Promise<void> {
    if (this.timer) { clearInterval(this.timer); this.timer = null; }
    // Do not cancel cloud work on exit, and do not silently mark persistent OpenCode sessions done.
    this.opencode.dispose();
  }
  private julesCapacity(): void {
    if (!this.jules.configured) throw new Error('JULES_API_KEY is missing; Jules REST is not authenticated');
    const now = this.now();
    const dayMax = Number(process.env.SC_JULES_DAILY_LIMIT ?? 100);
    const concurrentMax = Number(process.env.SC_JULES_CONCURRENT_LIMIT ?? 15);
    const prior = this.list().filter(s => s.pool === 'jules');
    // Fail closed if a current submission might still be in progress; this avoids duplicate launch after reboot.
    const daily = prior.filter(s => (s.startedAt ?? 0) > now - 86400000).length;
    const active = prior.filter(s => !final.has(s.status)).length;
    if (daily >= dayMax) throw new Error(`Jules REST daily allotment exhausted locally (${daily}/${dayMax} in 24h)`);
    if (active >= concurrentMax) throw new Error(`Jules REST concurrency exhausted locally (${active}/${concurrentMax})`);
  }
  async launch(p: ExternalLaunch): Promise<ExternalWorkerSpec> {
    if (!['opencode', 'agy', 'jules'].includes(p.pool)) throw new Error('Unknown external pool: ' + p.pool);
    if (!p.assignment.trim()) throw new Error('External worker assignment cannot be empty');
    if (p.pool === 'jules') this.julesCapacity();
    const id = `x-${p.pool}-${randomUUID().slice(0, 10)}`;
    const spec: ExternalWorkerSpec = {
      id, pool: p.pool, assignment: p.assignment, status: 'starting',
      repo: resolve(p.repo ?? this.root), model: p.model,
      startedAt: this.now(),
      metadata: {
        title: p.title ?? p.assignment.slice(0, 70), taskId: p.taskId,
        ...(p.source ? { source: p.source } : {}),
        ...(p.branch ? { branch: p.branch } : {}),
        requirePlanApproval: p.requirePlanApproval === true,
        autoCreatePr: p.autoCreatePr === true,
        timeoutMs: p.timeoutMs ?? 1800000,
        pendingMessages: [],
      },
    };
    await this.save(spec);
    try {
      if (p.pool === 'opencode') {
        const session = await this.opencode.create(p.title ?? id);
        await this.patch(id, { externalSessionId: session });
        const baseline = await this.opencode.submit(session, p.assignment, p.model);
        await this.patch(id, { status: 'running', metadata: { ...this.get(id).metadata, baseline } });
      } else if (p.pool === 'jules') {
        // Mark STARTING persistently before HTTP create. An ambiguous network failure is NOT retried automatically.
        const session = await this.jules.create(spec);
        await this.patch(id, { status: julesStatus(session.state), externalSessionId: session.name,
          metadata: { ...spec.metadata, url: session.url, remoteState: session.state } });
      } else {
        this.launchAgy(spec);
        await this.patch(id, { status: 'running' });
      }
    } catch (e) {
      await this.patch(id, { status: 'failed', endedAt: this.now(), note: String((e as Error).message).slice(0, 800) });
      throw new Error(`${id}: ${String((e as Error).message)}`);
    }
    return this.get(id);
  }

  private launchAgy(spec: ExternalWorkerSpec): void {
    let resultStatus = '';
    let resultNote = '';
    let conversation = '';
    const args = agyAdapter.buildArgs(spec);
    const handle = runExternal({
      command: process.env.SC_AGY_COMMAND ?? 'agy',
      args, cwd: spec.repo ?? this.root, logPath: this.store.logPath(spec.id),
      timeoutMs: Number(spec.metadata?.timeoutMs ?? 1800000),
      normalize: (line, stream): PoolEvent[] => {
        if (stream === 'stderr') {
          if (/permission denied|authentication required/i.test(line)) resultNote = line.slice(0, 500);
          return [{ type: 'progress', line: line.slice(0, 500) }];
        }
        try {
          const e = JSON.parse(line);
          const typ = e.event;
          const item = e.step_update ?? {};
          const r = e.result ?? {};
          const id = e.conversation_id ?? e.init?.conversation_id ?? item.conversation_id ?? r.conversation_id;
          if (typeof id === 'string') conversation = id;
          if (typ === 'result') {
            resultStatus = String(r.status ?? '').toUpperCase();
            resultNote = String(r.error ?? r.response ?? '').slice(-1500);
            return [{ type: 'progress', line: resultStatus + ': ' + resultNote.slice(0, 160) }];
          }
          if (typ === 'step_update') {
            if (item.tool_name) return [{ type: 'tool', name: String(item.tool_name) }];
            if (item.text_delta) return [{ type: 'text', text: String(item.text_delta) }];
          }
          return [];
        } catch { return [{ type: 'progress', line: line.slice(0, 200) }]; }
      },
    });
    this.processes.set(spec.id, handle);
    handle.on(ev => {
      if (ev.type === 'text' || ev.type === 'tool') {
        const action = ev.type === 'tool' ? 'tool ' + ev.name : ev.text.slice(-180);
        void this.patch(spec.id, { note: action }).catch(() => {});
      }
    });
    void handle.done().then(async r => {
      this.processes.delete(spec.id);
      const status: PoolWorkerStatus = r.timedOut ? 'timeout' : r.cancelled ? 'cancelled'
        : r.code === 0 && resultStatus === 'SUCCESS' ? 'succeeded' : 'failed';
      const existing = this.get(spec.id);
      await this.patch(spec.id, { status, externalSessionId: conversation || existing.externalSessionId,
        endedAt: this.now(), exitCode: r.code,
        note: (resultNote || r.error || `agy exit ${String(r.code)}; status ${resultStatus || 'missing result'}`).slice(-800) });
    }).catch(async e => {
      await this.patch(spec.id, { status: 'failed', endedAt: this.now(), note: String(e).slice(0, 800) });
    });
  }

  async refresh(): Promise<void> {
    if (this.ticking) return;
    this.ticking = true;
    const now = this.now();
    try {
      for (const s of this.list()) {
        if (s.pool === 'opencode' && ['running','streaming','waiting_input','starting'].includes(s.status)) {
          if (!s.externalSessionId) continue;
          try {
            const baseline = Number(s.metadata?.baseline ?? 0);
            const result = await this.opencode.inspect(s.externalSessionId, baseline);
            if (result.completed) {
              const pending = (s.metadata?.pendingMessages ?? []) as string[];
              if (pending.length) {
                const [next, ...tail] = pending;
                const start = await this.opencode.steer(s.externalSessionId, next!, s.model);
                await this.patch(s.id, { status: 'running', note: 'Following up: ' + next!.slice(0, 200),
                  metadata: { ...s.metadata, baseline: start, pendingMessages: tail } });
              } else {
                const changed = await this.opencode.diff(s.externalSessionId).catch(() => []);
                await this.patch(s.id, { status: result.status, endedAt: now, touchedPaths: changed, note: result.error ?? result.text });
              }
            } else if (result.status !== s.status) {
              await this.patch(s.id, { status: result.status, note: result.text });
            }
            if ((this.now() - (s.startedAt ?? now)) > Number(s.metadata?.timeoutMs ?? 1800000)) {
              await this.opencode.abort(s.externalSessionId);
              await this.patch(s.id, { status: 'timeout', endedAt: this.now(), note: 'OpenCode task timeout; session aborted' });
            }
          } catch (e) {
            await this.patch(s.id, { status: 'waiting_input', note: 'OpenCode poll: ' + String(e).slice(0, 450) });
          }
        }
        if (s.pool === 'jules' && now - this.lastJulesPoll >= 10000 && !final.has(s.status) && s.externalSessionId) {
          try {
            const current = await this.jules.get(s.externalSessionId);
            const status = julesStatus(current.state);
            await this.patch(s.id, { status, ...(isJulesTerminal(current.state) ? { endedAt: now } : {}),
              metadata: { ...s.metadata, remoteState: current.state, url: current.url ?? s.metadata?.url } });
            if (isJulesTerminal(current.state)) await this.collectJules(s.id);
          } catch (e) { await this.patch(s.id, { note: 'Jules poll: ' + String(e).slice(0, 500) }); }
        }
      }
      if (now - this.lastJulesPoll >= 10000) this.lastJulesPoll = now;
    } finally { this.ticking = false; }
  }

  async collectJules(id: string): Promise<void> {
    const spec = this.get(id);
    if (spec.pool !== 'jules' || !spec.externalSessionId) throw new Error('Not a dispatched Jules task');
    const { session, patches, notes } = await this.jules.collect(spec.externalSessionId);
    const latest = patches.at(-1);
    let patchFile = '';
    if (latest) {
      const dir = join(this.root, '.statefulclanker', 'pools', 'patches');
      await mkdir(dir, { recursive: true });
      patchFile = join(dir, spec.id + '.patch');
      await writeFile(patchFile, latest.patch, 'utf8');
    }
    await this.patch(id, { status: julesStatus(session.state),
      note: notes.at(-1) ?? (session.outputs?.length ? 'Remote output ready' : session.state),
      metadata: { ...spec.metadata, patchFile: patchFile || spec.metadata?.patchFile,
        baseCommitId: latest?.baseCommitId ?? spec.metadata?.baseCommitId, outputs: session.outputs } });
  }

  async applyJules(id: string): Promise<string> {
    const s = this.get(id);
    if (s.pool !== 'jules' || s.status !== 'succeeded') throw new Error('Jules run has not completed successfully');
    const path = s.metadata?.patchFile;
    if (typeof path !== 'string' || !path.startsWith(join(this.root, '.statefulclanker', 'pools', 'patches')))
      throw new Error('No retrieved Jules patch. Run external_worker_collect first.');
    if (s.metadata?.applied) return 'Already applied';
    const patch = await readFile(path);
    if (!patch.length) throw new Error('Empty Jules patch');
    // Never reset/checkout peers' work. A conflict is reported and the patch stays available.
    execFileSync('git', ['apply', '--check', '-'], { cwd: s.repo ?? this.root, input: patch, timeout: 10000 });
    execFileSync('git', ['apply', '-'], { cwd: s.repo ?? this.root, input: patch, timeout: 30000 });
    await this.patch(id, { metadata: { ...s.metadata, applied: true } });
    return 'Applied Jules patch to working tree; task still requires testing and verification';
  }

  async message(id: string, text: string): Promise<ExternalWorkerSpec> {
    const s = this.get(id);
    if (!text.trim()) throw new Error('Empty message');
    if (s.pool === 'jules') {
      if (!s.externalSessionId) throw new Error('Jules has no session');
      await this.jules.sendMessage(s.externalSessionId, text);
      return this.patch(id, { note: 'Steered Jules: ' + text.slice(0, 160) });
    }
    if (s.pool === 'opencode') {
      if (!s.externalSessionId) throw new Error('OpenCode has no session');
      if (final.has(s.status)) {
        const baseline = await this.opencode.steer(s.externalSessionId, text, s.model);
        return this.patch(id, { status: 'running', endedAt: undefined, note: text.slice(0, 200),
          metadata: { ...s.metadata, baseline, pendingMessages: [] } });
      }
      const pending = (s.metadata?.pendingMessages ?? []) as string[];
      return this.patch(id, { metadata: { ...s.metadata, pendingMessages: [...pending, text] },
        note: `Queued ${pending.length + 1} peer message(s)` });
    }
    throw new Error('agy one-shot worker cannot be steered after launch; dispatch a follow-up conversation job');
  }
  async approve(id: string): Promise<void> {
    const s = this.get(id);
    if (s.pool !== 'jules' || !s.externalSessionId) throw new Error('Not a Jules session');
    await this.jules.approvePlan(s.externalSessionId);
    await this.patch(id, { status: 'running', note: 'Jules plan approved' });
  }
  async cancel(id: string): Promise<void> {
    const s = this.get(id);
    if (s.pool === 'jules') throw new Error('Jules REST provides no session abort API; cannot assert cancellation of cloud work');
    if (s.pool === 'opencode' && s.externalSessionId) await this.opencode.abort(s.externalSessionId);
    if (s.pool === 'agy') await this.processes.get(id)?.cancel('operator requested');
    await this.patch(id, { status: 'cancelled', endedAt: this.now(), note: 'Cancelled by operator' });
  }
  async availability(): Promise<Record<string, unknown>> {
    const records = this.list();
    const day = this.now() - 86400000;
    return {
      opencode: { transport: 'session-server', executable: process.env.SC_OPENCODE_COMMAND ?? 'opencode',
        health: 'not_probed', note: 'OpenCode server is checked when a worker is dispatched' },
      agy: { transport: 'headless', executable: process.env.SC_AGY_COMMAND ?? 'agy',
        health: 'not_probed' },
      jules: { transport: 'rest', credentialPresent: this.jules.configured,
        recentSubmissions: records.filter(s => s.pool === 'jules' && (s.startedAt ?? 0) >= day).length,
        inFlight: records.filter(s => s.pool === 'jules' && !final.has(s.status)).length,
        dailyLimit: Number(process.env.SC_JULES_DAILY_LIMIT ?? 100),
        maxConcurrent: Number(process.env.SC_JULES_CONCURRENT_LIMIT ?? 15) },
    };
  }
}
