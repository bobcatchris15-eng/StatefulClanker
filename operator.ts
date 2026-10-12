import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { recordIntent } from './project/intent.ts';
import { reconstruct } from './project/reconstruct.ts';
import { createTask, getTask, listTasks, updateTask } from './project/tasks.ts';
import { renderRack, type RackOpts, type RackWorker } from './ui/worker-rack.ts';
import { renderSplitPanes, externalPoolIds, type PoolPaneInput } from './ui/pool-pane.ts';
import { ExternalPoolManager } from './pools/manager.ts';
import { RowSource } from './ui/row-source.ts';
import { DEFAULT_LAMPS, LampField, LARGE_LAMPS, RackClock } from './ui/lamp-bank.ts';
import { Key, matchesKey, visibleWidth } from '@earendil-works/pi-tui';
import { CatalogService } from './catalog/service.ts';
import { spawnSelected, WorkerManager, type SpawnLaunch } from './workers/manager.ts';
import { parentExtensionArgs } from './workers/runtime.ts';
import { getWorker, listWorkers } from './workers/registry.ts';
import { registerCheckoutTools } from './workspace/tools.ts';
import { dispatchNotices, proposalAssignment } from './workspace/dispatch.ts';
import { reconcileSolicitations } from './workspace/checkouts.ts';
import { registerLivingContext } from './context/runtime.ts';
import { registerMemoryTools } from './context/tools.ts';
import { registerWatchTools } from './context/watch-tools.ts';
import type { Solicitation } from './workspace/checkouts.ts';

const here = dirname(fileURLToPath(import.meta.url));
const prompt = (n: string) => readFileSync(join(here, 'prompts', n), 'utf8');
const txt = (s: string) => ({ content: [{ type: 'text' as const, text: s }], details: {} });
const opt = (t: any) => Type.Optional(t);
const strs = () => Type.Optional(Type.Array(Type.String()));

export function operatorMode(pi: ExtensionAPI): void {
  let cwd = process.cwd();
  let uiCtx: any = null;
  let mgr: WorkerManager | null = null;
  let external: ExternalPoolManager | null = null;
  const externalManager = (): ExternalPoolManager => external ??= new ExternalPoolManager(root(), {
    onChange: (job) => {
      // External workers submit receipts into the SAME task graph as native workers.
      // Their self-reported backend success NEVER counts as independent verification.
      const taskId = job.metadata?.taskId;
      if (typeof taskId === 'string' && ['succeeded', 'failed', 'cancelled', 'timeout', 'lost'].includes(job.status)) {
        try {
          const task = getTask(root(), taskId);
          if (task && !['complete', 'failed', 'cancelled'].includes(task.status)
              && !task.results.some((r: any) => r.kind === 'verification')) {
            const submission = {
              kind: 'worker_submission', worker_id: job.id, backend: job.pool,
              status: job.status, summary: job.note ?? '',
              changed_files: job.touchedPaths ?? [], patch_file: job.metadata?.patchFile,
              session_id: job.externalSessionId, at: new Date().toISOString(),
            };
            const results = task.results.filter((r: any) => r.kind !== 'worker_submission' || r.worker_id !== job.id);
            results.push(submission);
            updateTask(root(), taskId, { status: job.status === 'succeeded' ? 'review' : 'blocked',
              assigned_worker: job.id, results });
          }
        } catch { /* task may be racing initial creation; next status event can recover */ }
      }
      draw();
    },
  });
  function externalPanes(): PoolPaneInput[] {
    const rows = external?.list() ?? [];
    return externalPoolIds().map(pool => ({
      pool,
      jobs: rows.filter(s => s.pool === pool).map(s => ({
        id: s.id, title: String(s.metadata?.title ?? s.assignment.slice(0, 60)),
        status: s.status === 'streaming' ? 'running' : s.status === 'timeout' || s.status === 'lost' ? 'failed' : s.status,
        startedAtMs: s.startedAt, endedAtMs: s.endedAt,
        changedFiles: s.touchedPaths?.length ?? (s.metadata?.patchFile ? 1 : 0),
      })),
    }));
  }
  let first = true;
  let collabTimer: NodeJS.Timeout | null = null;
  let collabActive = false;
  let lastCollabError = '';
  const root = () => process.env.SC_PROJECT_ROOT ?? cwd;
  const launch = (): SpawnLaunch => ({
    extensionPath: join(here, 'index.ts'), piCommand: process.execPath,
    args: process.argv[1] ? [process.argv[1]] : [],
    extraExtensions: parentExtensionArgs(process.argv, join(here, 'index.ts')),
    env: process.env.PI_CODING_AGENT_DIR ? { PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR } : {},
  });

  let timer: NodeJS.Timeout | null = null;
  let last = 0;
  // Supervisor panel: a setWidget component, so width and theme come from the TUI itself
  // (render(width) / ui.theme) instead of process.stdout.columns. Draw state is pushed into
  // `rack` and the component is invalidated; it never rebuilds lines with stale ANSI.
  const rack: { workers: RackWorker[]; comp: { invalidate(): void } | null; tui: { requestRender(): void } | null } =
    { workers: [], comp: null, tui: null };
  // Blinkenlights: the lamp field (which workers are on the panel and what colour their
  // bulbs burn) plus the animation clock. The clock is clamped elapsed time, never a
  // shared phase - every lamp runs its own oscillator against it, so the renderer stays
  // pure and unit-testable while the rack stays gloriously unsynchronized.
  const banks = new LampField(LARGE_LAMPS);
  const clock = new RackClock();
  const TICK_MS = 100;          // ~10fps: fast enough for the quickest bulb, cheap enough to ignore
  const ROWS_EVERY_MS = 500;    // registry re-read while animating
  let tick: NodeJS.Timeout | null = null;
  /** True when there is an interactive terminal to animate for. */
  const animatable = () => Boolean(uiCtx?.hasUI && uiCtx.mode === 'tui');

  function rackRows(): RackWorker[] {
    const titles = new Map<string, string>();
    try { for (const t of listTasks(root())) titles.set(t.id, t.title); } catch { /* no task store yet */ }
    return listWorkers(root()).map((w: any) => ({ ...w, task_title: w.task_id ? titles.get(w.task_id) : undefined }));
  }
  /**
   * Worker rows, refreshed defensively. Reads are captured rather than thrown so a transient bad
   * read (the registry is written concurrently by worker processes, and `listWorkers` takes no
   * lock) cannot kill the poll or blank the pane; the previous snapshot simply stays on screen.
   */
  const rowFeed = new RowSource<RackWorker[]>({
    read: rackRows,
    everyMs: 500,
    onError: (e) => { if (!lastRowsError) lastRowsError = e instanceof Error ? e.message : String(e); },
  });
  let lastRowsError = '';
  /** Pull worker rows if stale and refresh the lamp field's view of who is on the panel. */
  function syncRows(now: number): void {
    const ok = rowFeed.ensureFresh(now);
    if (ok && rowFeed.rows) {
      rack.workers = rowFeed.rows;
      // Idempotent liveness + status sync, so a periodic re-read never disturbs a lamp bank.
      banks.sync(rack.workers, now);
      banks.prune(rack.workers.map((w) => w.id), 60_000, now);
    }
    if (rowFeed.failures === 0) lastRowsError = '';
  }
  function rackOptions(extra: Partial<RackOpts> = {}): RackOpts {
    return {
      theme: (uiCtx?.ui?.theme ?? undefined) as any,
      nowMs: clock.elapsedMs,
      ...extra,
    };
  }
  function rackComponent(tui: any): any {
    rack.tui = tui;
    const comp = {
      invalidate(): void { /* data is read fresh in render() */ },
      render(width: number): string[] {
        // Theme is read per render so a theme switch is picked up without re-registering the widget.
        const hasExternal = (external?.list().length ?? 0) > 0;
        if (!hasExternal) return renderRack(rack.workers, width, rackOptions({ maxLamps: DEFAULT_LAMPS }));
        // Render rack inside its own width first; the compositor clamps it in the split.
        const nativeWidth = Math.max(24, Math.floor(width / (1 + externalPanes().filter(p => p.jobs.length).length)));
        const nativeLines = renderRack(rack.workers, nativeWidth, rackOptions({ maxLamps: DEFAULT_LAMPS }));
        return renderSplitPanes({ rackLines: nativeLines }, externalPanes(), width, { nowMs: Date.now() });
      },
      dispose(): void { rack.comp = null; },
    };
    rack.comp = comp;
    return comp;
  }
  function installWidget(): void {
    if (!animatable()) return;
    try { uiCtx.ui.setWidget('sc-rack', rackComponent); } catch { /* ctx stale */ }
  }
  /**
   * Animation ticker. Advances clamped animation time (so a suspended laptop cannot make
   * the lamps jump) and asks Pi for a coalesced re-render. Worker rows are re-read on a
   * slower cadence than time advances. Never runs without an interactive TUI, is
   * unref'd so it cannot hold the process open, and is cleared on shutdown.
   */
  function startTicker(): void {
    if (tick || !animatable()) return;
    // The feed and the ticker are independent: rows refresh on their own cadence so a pane that is
    // not animating (custom screens, paused UIs) still learns about finished work.
    rowFeed.start();
    tick = setInterval(() => {
      // Every body statement is guarded: an escape from here would leave a half-updated pane
      // (clock advancing, rows frozen) that looks alive right up until it is hours stale.
      try {
        const now = Date.now();
        syncRows(now);
        clock.advance(now);
      } catch { /* the pane keeps its last good snapshot */ }
      try { rack.tui?.requestRender(); } catch { /* ctx stale */ }
    }, TICK_MS);
    tick.unref?.();
  }
  function stopTicker(): void {
    rowFeed.stop();
    if (!tick) return;
    clearInterval(tick);
    tick = null;
  }
  function drawNow(): void {
    timer = null; last = Date.now();
    if (!uiCtx?.hasUI) return;
    syncRows(last);
    if (!rack.comp) installWidget();
    rack.comp?.invalidate();
    try { rack.tui?.requestRender(); } catch { /* ctx stale */ }
    startTicker();
  }
  function draw(): void {
    if (timer) return;
    timer = setTimeout(drawNow, Math.max(0, 300 - (Date.now() - last)));
    timer.unref();
  }

  /** Fullscreen mainframe console: the same pure renderer, full lamp banks plus the state legend. */
  function rackConsole(): Promise<void> {
    if (!animatable()) return Promise.resolve();
    return uiCtx.ui.custom((tui: any, theme: any, _keyb: any, done: (v: void) => void) => {
      rack.tui = tui;
      const comp = {
        invalidate(): void { /* data is read fresh in render() */ },
        render(width: number): string[] {
          const now = Date.now();
          syncRows(now);
          clock.advance(now);
          const w = Math.max(0, Math.floor(width));
          const lines = renderRack(rack.workers, w, rackOptions({ theme, maxRows: 64, maxLamps: LARGE_LAMPS, legend: true }));
          const hint = (theme as any)?.fg?.('muted', 'esc/q close') ?? 'esc/q close';
          return [...lines, visibleWidth(hint) <= w ? hint : hint.slice(0, Math.max(0, w - 1))];
        },
        handleInput(data: string): void {
          if (matchesKey(data, Key.escape) || matchesKey(data, Key.enter) || data === 'q' || data === 'Q') done(undefined);
        },
        dispose(): void { /* the shared clock and banks outlive this screen */ },
      };
      startTicker();
      return comp;
    }).then(() => undefined).catch(() => undefined);
  }

  let cat: CatalogService | null = null;
  const catalog = (): CatalogService => cat ??= new CatalogService({
    root: root(), getContext: () => uiCtx ?? { modelRegistry: { getAvailable: () => [] } },
  });

  const manager = (): WorkerManager => {
    if (mgr) return mgr;
    const m = new WorkerManager(root(), { catalog: catalog() });
    m.on('result', (id: string, r: any, file: string) => {
      const files = r.changed_files?.length ? ` files=${r.changed_files.join(',')}` : '';
      const unres = r.unresolved_questions?.length ? `\nunresolved: ${r.unresolved_questions.join('; ')}` : '';
      const risks = r.known_risks?.length ? `\nrisks: ${r.known_risks.join('; ')}` : '';
      const nm = getWorker(root(), id)?.display_name;
      pi.sendMessage({
        customType: 'sc-worker-result', display: true, details: { worker: id, task: r.task_id, receipt: file },
        content: `Worker ${id}${nm ? ` (${nm})` : ''} finished task ${r.task_id}: ${r.status}\n${r.summary}${files}${unres}${risks}`,
      }, { deliverAs: 'followUp', triggerTurn: true });
      draw();
    });
    m.on('event', draw);
    m.on('collaboration', () => { void pumpCollaboration(); });
    m.on('exit', draw);
    mgr = m;
    return m;
  };

  /**
   * Parent is the only runtime delivery/spawn broker. This loop also replays undelivered
   * notices after a crash; child workers only enqueue durable intent into the ledger.
   */
  async function pumpCollaboration(): Promise<void> {
    if (collabActive) return;
    collabActive = true;
    try {
      reconcileSolicitations(root(), (id) => {
        const w = getWorker(root(), id);
        return !!w && !['COMPLETE', 'CANCELLED', 'FAILED', 'LOST'].includes(w.status);
      });
      await dispatchNotices(root(), {
        async sendWorker(id, message) {
          const w = getWorker(root(), id);
          const rt = manager().runtime(id);
          if (!w || ['COMPLETE', 'CANCELLED', 'FAILED', 'LOST'].includes(w.status) || !rt || rt.exited || rt.stopping)
            throw Error('worker is no longer available');
          if (rt.streaming) await manager().message(id, message);
          else await manager().followUp(id, message);
        },
        notifyOperator(message) {
          pi.sendMessage({
            customType: 'sc-collaboration', display: true, details: { kind: 'collaboration' },
            content: message,
          }, { deliverAs: 'followUp', triggerTurn: true });
        },
        canSpawn() {
          return listWorkers(root()).filter((w) =>
            !['COMPLETE', 'CANCELLED', 'FAILED', 'LOST'].includes(w.status)).length < 3;
        },
        async spawn(q: Solicitation) {
          const owner = q.owner === 'operator' ? null : getWorker(root(), q.owner);
          if (q.owner !== 'operator' && (!owner ||
            ['COMPLETE', 'CANCELLED', 'FAILED', 'LOST'].includes(owner.status)))
            return { error: 'requesting checkout owner is not active; transfer or close the solicitation' };
          const result = await spawnSelected(manager(), catalog(), root(), {
            assignment: proposalAssignment(q),
            role: 'proposal-helper', ability_profile: q.ability_profile,
            preferences: { free_only: true },
            task_title: 'Proposal assistance ' + q.paths.join(', ').slice(0, 70),
            files: [], context_hints: ['solicitation:' + q.id],
          }, launch());
          return result.ok ? { worker_id: result.worker_id } : { error: result.error ?? 'no available model' };
        },
      });
      lastCollabError = '';
    } catch (err) {
      const msg = String((err as Error).message);
      if (msg !== lastCollabError) {
        lastCollabError = msg;
        pi.sendMessage({
          customType: 'sc-collaboration-error', display: true, details: {},
          content: 'Collaboration dispatcher error: ' + msg,
        }, { deliverAs: 'followUp', triggerTurn: true });
      }
    } finally {
      collabActive = false;
    }
  }

  pi.on('session_start', async (_e: any, ctx: any) => {
    cwd = ctx.cwd ?? cwd; uiCtx = ctx; first = true;
    clock.reset();
    manager().recover();
    await externalManager().start().catch((e: unknown) => {
      pi.sendMessage({ customType: 'sc-external-error', display: true, content: 'External pools: ' + String(e) }, { deliverAs: 'followUp', triggerTurn: false });
    });
    reconcileSolicitations(root(), (id) => {
      const w = getWorker(root(), id);
      return !!w && !['COMPLETE', 'CANCELLED', 'FAILED', 'LOST'].includes(w.status);
    }, true);
    if (collabTimer) clearInterval(collabTimer);
    // Guarded like the ticker: an escape from this callback would return a rejected promise into
    // the void and quietly stop every later proposal notification, leaving work requests unserved.
    collabTimer = setInterval(() => {
      try { void pumpCollaboration().catch(() => undefined); } catch { /* transient registry read */ }
    }, 500);
    collabTimer.unref();
    void pumpCollaboration().catch(() => undefined);
    syncRows(Date.now());
    installWidget();
    drawNow();
  });
  pi.on('session_shutdown', async () => {
    if (collabTimer) { clearInterval(collabTimer); collabTimer = null; }
    stopTicker();
    await external?.stop();
    banks.clear();
    if (!mgr) return;
    try { uiCtx?.ui?.setWidget('sc-rack', undefined); } catch { /* ctx stale */ }
    for (const w of listWorkers(root())) { try { await mgr.runtime(w.id)?.stop(); } catch { /* */ } }
    mgr.releaseAll();
  });
  pi.on('before_agent_start', async (event: any) => {
    let extra = `${prompt('authority.md')}\n\n${prompt('common.md')}\n\n${prompt('operator.md')}`;
    if (first) { first = false; extra += `\n\n${reconstruct(root())}`; }
    if (event.systemPromptOptions?.sections) {
      event.systemPromptOptions.sections['statefulclanker-core'] = extra;
      return;
    }
    return { systemPrompt: `${event.systemPrompt}\n\n${extra}` };
  });

  registerCheckoutTools(pi, root, () => 'operator', true);
  registerMemoryTools(pi, root, () => 'operator', true);
  registerWatchTools(pi, root, () => 'operator');
  registerLivingContext(pi, root, () => 'operator');

  /** External clients do not load Pi extension prompts or hooks. Give them a bounded,
   * self-contained task packet including the current shared foundation and file scope.
   * Never embed credentials, private machine state or full Pi transcripts. */
  function externalAssignment(p: any, taskId: string): string {
    let foundation = '';
    try { foundation = readFileSync(join(root(), '.clanker', 'foundation.md'), 'utf8').slice(0, 12000); }
    catch { /* project has no foundation yet */ }
    const files = Array.isArray(p.files) ? p.files.filter((x: unknown) => typeof x === 'string') : [];
    const expected = Array.isArray(p.expected_outputs) ? p.expected_outputs : [];
    const hints = Array.isArray(p.context_hints) ? p.context_hints : [];
    return [
      '# StatefulClanker external worker assignment',
      'You are a coding/research worker supervised by StatefulClanker. Work in the supplied repository.',
      'Do not invent work completed. Test your changes and report limitations and actual modified paths.',
      'The checkout is shared with peer workers; read their uncommitted changes and avoid modifying files outside your assignment.',
      'Do not reset, clean, revert or hard-checkout the shared working tree; do not stage unrelated files.',
      'For Jules: you are working on the pushed GitHub revision rather than the live local checkout; return changes as a patch/PR.',
      'The operator owns final verification and publication. You do not need to request approval for routine task-scoped edits.',
      `Task ID: ${taskId}`,
      '## Assignment', String(p.assignment),
      '## File scope', files.length ? files.join('\\n') : 'No explicit file scope; minimize overlapping writes.',
      '## Expected outputs', expected.length ? expected.join('\\n') : 'Working changes and a concise evidence-backed summary.',
      '## Context hints', hints.join('\\n') || '(none)',
      '## Shared foundation (bounded)', foundation || '(not available)',
    ].join('\\n\\n');
  }

  pi.registerTool({
    name: 'worker_spawn', label: 'Spawn Worker',
    description: 'Select a model by ability profile (never inherits yours), create task, assign file checkout responsibility in one shared working tree, spawn a worker. Non-blocking. Use dry_run to inspect the choice.',
    parameters: Type.Object({
      assignment: Type.String(),
      backend: opt(Type.Union([Type.Literal('pi'), Type.Literal('opencode'), Type.Literal('agy'), Type.Literal('jules')])),
      source: opt(Type.String({ description: 'Jules connected source name, e.g. sources/github/org/repo' })),
      branch: opt(Type.String({ description: 'Jules starting remote branch, defaults to main' })),
      model: opt(Type.String({ description: 'Explicit provider/id; only when the human names a model' })),
      ability_profile: opt(Type.String({ description: 'implementation|research|architecture|review|fast' })),
      requirements: opt(Type.Object({
        min: opt(Type.Record(Type.String(), Type.String())), weights: opt(Type.Record(Type.String(), Type.Number())),
        min_context: opt(Type.Number()),
      })),
      preferences: opt(Type.Object({ free_only: opt(Type.Boolean()), prefer_provider: strs(), avoid_provider: strs(), diversity_from: strs() })),
      relationship: opt(Type.Object({ independent: opt(Type.Boolean()), independent_of: opt(Type.String()) })),
      dry_run: opt(Type.Boolean()),
      role: opt(Type.String()), task_title: opt(Type.String()), files: strs(),
      expected_outputs: strs(), context_hints: strs(),
    }),
    async execute(_id: string, p: any, _s: any, _u: any, ctx: any) {
      if (ctx) uiCtx = ctx;
      if (p.backend && p.backend !== 'pi') {
        if (p.dry_run) return txt(JSON.stringify({ backend: p.backend, dry_run: true, note: 'External backend uses its own authentication and quota; not a Pi model endpoint' }));
        try {
          const task = createTask(root(), { title: p.task_title ?? p.assignment.slice(0, 70), objective: p.assignment,
            expected_outputs: p.expected_outputs ?? [], context_hints: p.context_hints ?? [] });
          const job = await externalManager().launch({
            pool: p.backend, assignment: externalAssignment(p, task.id), title: p.task_title, taskId: task.id,
            model: p.model, repo: root(), source: p.source, branch: p.branch,
          });
          updateTask(root(), task.id, { assigned_worker: job.id, status: 'active' });
          draw();
          return txt(JSON.stringify({ worker_id: job.id, backend: job.pool, session_id: job.externalSessionId,
            task_id: task.id, status: job.status, note: 'Backend completion requires independent task_verify' }));
        } catch (e) { return txt('error: ' + String(e)); }
      }
      const r = await spawnSelected(manager(), catalog(), root(), p, launch());
      if (p.dry_run) {
        const s = r.selection ?? {};
        return txt(JSON.stringify({ dry_run: true, ok: r.ok, chosen: s.chosen?.key ?? null, reason: s.reason, ranked: s.ranked, excluded: s.excluded, error: r.error }, null, 1));
      }
      if (!r.ok) return txt(`error: ${r.error}`);
      draw();
      return txt(JSON.stringify({ worker_id: r.worker_id, name: null, model: r.model, reason: r.selection?.reason, workspace: r.workspace, checkout_conflicts: r.checkout_conflicts, task_id: r.task_id }));
    },
  });

  pi.registerTool({
    name: 'external_worker_list', label: 'External Workers',
    description: 'List OpenCode, agy and Jules workers and their independent quota / backend health.',
    parameters: Type.Object({}),
    async execute() {
      return txt(JSON.stringify({ jobs: externalManager().list().map(s => ({
        id: s.id, pool: s.pool, status: s.status, session: s.externalSessionId,
        note: s.note, changed_files: s.touchedPaths, task: s.metadata?.taskId,
        url: s.metadata?.url, patch_file: s.metadata?.patchFile,
      })), availability: await externalManager().availability() }, null, 2));
    },
  });
  pi.registerTool({
    name: 'external_worker_refresh', label: 'Refresh External Workers',
    description: 'Poll OpenCode and Jules now; no inference call or new session is created.',
    parameters: Type.Object({}),
    async execute() { await externalManager().refresh(); draw(); return txt(JSON.stringify(externalManager().list(), null, 2)); },
  });
  pi.registerTool({
    name: 'external_worker_message', label: 'Message External Worker',
    description: 'Steer a Jules session or queue a follow-up in an existing OpenCode session. Reuses the same worker.',
    parameters: Type.Object({ worker_id: Type.String(), message: Type.String() }),
    async execute(_i: string, p: any) {
      try { const s = await externalManager().message(p.worker_id, p.message); draw(); return txt(JSON.stringify({ id: s.id, status: s.status, session: s.externalSessionId, note: s.note })); }
      catch (e) { return txt('error: ' + String(e)); }
    },
  });
  pi.registerTool({
    name: 'external_worker_cancel', label: 'Cancel External Worker',
    description: 'Cancel a local OpenCode/agy worker; Jules REST does not expose a reliable abort endpoint.',
    parameters: Type.Object({ worker_id: Type.String() }),
    async execute(_i: string, p: any) {
      try { await externalManager().cancel(p.worker_id); draw(); return txt('Cancellation requested'); }
      catch (e) { return txt('error: ' + String(e)); }
    },
  });
  pi.registerTool({
    name: 'external_worker_collect', label: 'Collect Jules Results',
    description: 'Retrieve Jules activities and any latest gitPatch into a durable local .patch file. Does not apply changes.',
    parameters: Type.Object({ worker_id: Type.String() }),
    async execute(_i: string, p: any) {
      try { await externalManager().collectJules(p.worker_id); draw(); return txt(JSON.stringify(externalManager().get(p.worker_id), null, 2)); }
      catch (e) { return txt('error: ' + String(e)); }
    },
  });
  pi.registerTool({
    name: 'external_worker_apply', label: 'Apply Jules Patch',
    description: 'Explicitly apply a completed Jules git patch to the shared checkout without resetting any peer edits. Conflicts leave patch intact.',
    parameters: Type.Object({ worker_id: Type.String() }),
    async execute(_i: string, p: any) {
      try { const r = await externalManager().applyJules(p.worker_id); draw(); return txt(r); }
      catch (e) { return txt('error: ' + String(e)); }
    },
  });
  pi.registerTool({
    name: 'external_worker_approve', label: 'Approve Jules Plan',
    description: 'Approve an awaiting Jules plan via the REST API.',
    parameters: Type.Object({ worker_id: Type.String() }),
    async execute(_i: string, p: any) {
      try { await externalManager().approve(p.worker_id); draw(); return txt('Plan approved'); }
      catch (e) { return txt('error: ' + String(e)); }
    },
  });

  const OUTCOMES = ['success', 'rate_limit', 'timeout', 'auth_error', 'malformed_tool_call', 'bad_continuation', 'tool_recovery', 'task_failure'];
  pi.registerTool({
    name: 'endpoint_list', label: 'List Endpoints', description: 'Model pool: key, ratings (source-tagged), free, health, lease use/capacity.',
    parameters: Type.Object({}),
    async execute(_i: string, _p: any, _s: any, _u: any, ctx: any) {
      if (ctx) uiCtx = ctx;
      const { rows, excluded } = catalog().list();
      const lines = rows.map((x) => `${x.key} free=${x.free} health=${x.health} leases=${x.leases} ratings=${x.ratings}`);
      const ex = excluded.map((e) => `excluded ${e.key}: ${e.why}`);
      return txt([...lines, ...ex].join('\n') || '(no models)');
    },
  });
  pi.registerTool({
    name: 'endpoint_status', label: 'Endpoint Status', description: 'Profile, health, leases and observations for one provider/id.',
    parameters: Type.Object({ model: Type.String() }),
    async execute(_i: string, p: any, _s: any, _u: any, ctx: any) {
      if (ctx) uiCtx = ctx;
      return txt(JSON.stringify(catalog().status(p.model), null, 1));
    },
  });
  pi.registerTool({
    name: 'endpoint_report', label: 'Report Endpoint Outcome', description: 'Record an outcome for a model (updates observations and health).',
    parameters: Type.Object({ model: Type.String(), outcome: Type.String(), task_class: opt(Type.String()), note: opt(Type.String()) }),
    async execute(_i: string, p: any, _s: any, _u: any, ctx: any) {
      if (ctx) uiCtx = ctx;
      if (!OUTCOMES.includes(p.outcome)) return txt(`error: outcome must be one of ${OUTCOMES.join('|')}`);
      const h = catalog().reportOutcome(p.model, p.outcome, { task_class: p.task_class, note: p.note });
      return txt(`${p.model} ${h.state} streak=${h.failure_streak}`);
    },
  });
  pi.registerTool({
    name: 'profile_set', label: 'Set Model Profile', description: 'Write a curated capability profile for a model glob pattern.',
    parameters: Type.Object({
      pattern: Type.String(), scope: Type.String({ description: 'machine|project' }),
      capabilities: opt(Type.Record(Type.String(), Type.String())), quirks: opt(Type.Record(Type.String(), Type.Any())),
      lease_capacity: opt(Type.Number()),
    }),
    async execute(_i: string, p: any) {
      if (p.scope !== 'machine' && p.scope !== 'project') return txt('error: scope must be machine|project');
      try { return txt(`wrote ${catalog().setProfile(p)}`); } catch (e) { return txt(`error: ${(e as Error).message}`); }
    },
  });

  pi.registerCommand('rack', {
    description: 'Blinkenlight supervisor console: full lamp banks per worker plus a state legend (esc to close)',
    handler: async (_name: string, ctx: any) => {
      if (ctx) uiCtx = ctx;
      syncRows(Date.now());
      await rackConsole();
    },
  });

  const line = (w: any) => `${w.id}${w.display_name ? ` ${w.display_name}` : ''} ${w.status} ${w.provider}/${w.model} task=${w.task_id}${w.current_action ? ` "${w.current_action}"` : ''}`;
  pi.registerTool({
    name: 'worker_list', label: 'List Workers', description: 'List workers with status.', parameters: Type.Object({}),
    async execute() { const ws = listWorkers(root()); return txt(ws.length ? ws.map(line).join('\n') : '(no workers)'); },
  });
  pi.registerTool({
    name: 'worker_status', label: 'Worker Status', description: 'Status of one worker incl. last result summary.',
    parameters: Type.Object({ id: Type.String() }),
    async execute(_i: string, p: any) {
      const w = getWorker(root(), p.id);
      if (!w) return txt(`no worker ${p.id}`);
      const r = w.results[w.results.length - 1];
      return txt(line(w) + `\nworkspace=${root()}` + (r ? `\nresult: ${r.status} ${r.summary}` : ''));
    },
  });
  const act = (name: string, desc: string, fn: (id: string, text: string) => Promise<unknown>) =>
    pi.registerTool({
      name, label: name, description: desc, parameters: Type.Object({ id: Type.String(), text: Type.String() }),
      async execute(_i: string, p: any) { try { await fn(p.id, p.text); return txt('sent'); } catch (e) { return txt(`error: ${(e as Error).message}`); } },
    });
  act('worker_message', 'Steer a running worker.', (id, t) => manager().message(id, t));
  act('worker_follow_up', 'Queue a follow-up for a worker.', (id, t) => manager().followUp(id, t));
  pi.registerTool({
    name: 'worker_cancel', label: 'Cancel Worker', description: 'Abort a worker.', parameters: Type.Object({ id: Type.String() }),
    async execute(_i: string, p: any) { try { await manager().cancel(p.id); draw(); return txt('cancelled'); } catch (e) { return txt(`error: ${(e as Error).message}`); } },
  });
  pi.registerTool({
    name: 'worker_retire', label: 'Retire Worker', description: 'Stop and archive a worker.', parameters: Type.Object({ id: Type.String() }),
    async execute(_i: string, p: any) { await manager().retire(p.id); draw(); return txt('retired'); },
  });
  pi.registerTool({
    name: 'task_create', label: 'Create Task', description: 'Create a task record.',
    parameters: Type.Object({ title: Type.String(), objective: Type.String(), files: strs() }),
    async execute(_i: string, p: any) {
      const t = createTask(root(), { title: p.title, objective: p.objective, scope: { files: p.files ?? [], subsystem: '', worktree: '' } });
      return txt(`${t.id} ${t.status} ${t.title}`);
    },
  });
  pi.registerTool({
    name: 'task_status', label: 'Task Status', description: 'One task, or all tasks if id omitted.',
    parameters: Type.Object({ id: opt(Type.String()) }),
    async execute(_i: string, p: any) {
      if (p.id) { const t = getTask(root(), p.id); return txt(t ? `${t.id} ${t.status} ${t.title} worker=${t.assigned_worker ?? '-'}` : `no task ${p.id}`); }
      const ts = listTasks(root());
      return txt(ts.length ? ts.map((t) => `${t.id} ${t.status} ${t.title}`).join('\n') : '(no tasks)');
    },
  });
  pi.registerTool({
    name: 'task_update', label: 'Update Task', description: 'Update task status/title/objective.',
    parameters: Type.Object({ id: Type.String(), status: opt(Type.String()), title: opt(Type.String()), objective: opt(Type.String()) }),
    async execute(_i: string, p: any) {
      const { id, ...patch } = p;
      try { const t = updateTask(root(), id, patch); return txt(`${t.id} ${t.status}`); } catch (e) { return txt(`error: ${(e as Error).message}`); }
    },
  });
  pi.registerTool({
    name: 'task_verify', label: 'Verify Task',
    description: 'Record independent evidence for a worker submission; only verified outcomes train task capability ratings.',
    parameters: Type.Object({
      id: Type.String(), passed: Type.Boolean(), evidence: Type.Array(Type.String(), { minItems: 1 }),
      note: opt(Type.String()),
    }),
    async execute(_i: string, p: any) {
      try {
        const t = getTask(root(), p.id);
        if (!t) return txt('error: task not found');
        if (!t.results.some((r: any) => r.kind === 'worker_submission'))
          return txt('error: no worker submission to verify');
        if (t.results.some((r: any) => r.kind === 'verification'))
          return txt('error: task already verified; create a new task for subsequent changes');
        const w = t.assigned_worker ? getWorker(root(), t.assigned_worker) : null;
        const externalJob = !w && t.assigned_worker ? external?.list().find(j => j.id === t.assigned_worker) : undefined;
        if (!w && !externalJob) return txt('error: worker record unavailable; recovery required');
        const taskClass: Record<string, string> = {
          implementation: 'coding', research: 'research', architecture: 'reasoning',
          review: 'reasoning', fast: 'speed',
        };
        const verdict = { kind: 'verification', passed: p.passed, evidence: p.evidence,
          note: p.note ?? '', at: new Date().toISOString(), verifier: 'operator' };
        updateTask(root(), t.id, { status: p.passed ? 'complete' : 'failed',
          results: [...t.results, verdict] });
        if (w) catalog().recordTaskVerification(w.provider + '/' + w.model, p.passed,
          taskClass[w.ability_profile] ?? 'coding', t.id);
        // External pools have their own model catalogs and quota accounting.
        // Do not contaminate native Pi model observations with their task results.
        return txt(JSON.stringify({ task_id: t.id, verdict: p.passed ? 'verified' : 'rejected',
          executor: w ? w.provider + '/' + w.model : externalJob?.pool,
          evidence: p.evidence }));
      } catch (e) { return txt('error: ' + (e as Error).message); }
    },
  });
  pi.registerTool({
    name: 'intent_record', label: 'Record Intent', description: 'Record human intent (supersedes earlier intents).',
    parameters: Type.Object({ statement: Type.String(), scope: opt(Type.String()), supersedes: strs() }),
    async execute(_i: string, p: any) {
      const i = recordIntent(root(), { statement: p.statement, scope: p.scope ?? '', supersedes: p.supersedes ?? [], source: 'human' });
      return txt(`${i.id} recorded`);
    },
  });
}
