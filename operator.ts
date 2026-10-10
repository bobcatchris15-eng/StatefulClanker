import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { recordIntent } from './project/intent.ts';
import { reconstruct } from './project/reconstruct.ts';
import { createTask, getTask, listTasks, updateTask } from './project/tasks.ts';
import { renderRack } from './ui/worker-rack.ts';
import { CatalogService } from './catalog/service.ts';
import { spawnSelected, WorkerManager, type SpawnLaunch } from './workers/manager.ts';
import { parentExtensionArgs } from './workers/runtime.ts';
import { getWorker, listWorkers } from './workers/registry.ts';
import { registerCheckoutTools } from './workspace/tools.ts';
import { dispatchNotices, proposalAssignment } from './workspace/dispatch.ts';
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
  function drawNow(): void {
    timer = null; last = Date.now();
    if (!uiCtx?.hasUI) return;
    try { uiCtx.ui.setWidget('sc-rack', renderRack(listWorkers(root()), process.stdout.columns || 80)); } catch { /* ctx stale */ }
  }
  function draw(): void {
    if (timer) return;
    timer = setTimeout(drawNow, Math.max(0, 300 - (Date.now() - last)));
    timer.unref();
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
    manager().recover();
    if (collabTimer) clearInterval(collabTimer);
    collabTimer = setInterval(() => { void pumpCollaboration(); }, 500);
    collabTimer.unref();
    void pumpCollaboration();
    drawNow();
  });
  pi.on('session_shutdown', async () => {
    if (collabTimer) { clearInterval(collabTimer); collabTimer = null; }
    if (!mgr) return;
    for (const w of listWorkers(root())) { try { await mgr.runtime(w.id)?.stop(); } catch { /* */ } }
    mgr.releaseAll();
  });
  pi.on('before_agent_start', async (event: any) => {
    let extra = `${prompt('operator.md')}\n\n${prompt('authority.md')}`;
    if (first) { first = false; extra += `\n\n${reconstruct(root())}`; }
    return { systemPrompt: `${event.systemPrompt}\n\n${extra}` };
  });

  registerCheckoutTools(pi, root, () => 'operator', true);

  pi.registerTool({
    name: 'worker_spawn', label: 'Spawn Worker',
    description: 'Select a model by ability profile (never inherits yours), create task, assign file checkout responsibility in one shared working tree, spawn a worker. Non-blocking. Use dry_run to inspect the choice.',
    parameters: Type.Object({
      assignment: Type.String(),
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
    name: 'intent_record', label: 'Record Intent', description: 'Record human intent (supersedes earlier intents).',
    parameters: Type.Object({ statement: Type.String(), scope: opt(Type.String()), supersedes: strs() }),
    async execute(_i: string, p: any) {
      const i = recordIntent(root(), { statement: p.statement, scope: p.scope ?? '', supersedes: p.supersedes ?? [], source: 'human' });
      return txt(`${i.id} recorded`);
    },
  });
}
