import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { recordIntent } from './project/intent.ts';
import { reconstruct } from './project/reconstruct.ts';
import { createTask, getTask, listTasks, updateTask } from './project/tasks.ts';
import { BlinkenState, renderRack, type RackWorker } from './ui/worker-rack.ts';
import { CatalogService } from './catalog/service.ts';
import { spawnSelected, WorkerManager } from './workers/manager.ts';
import { parentExtensionArgs } from './workers/runtime.ts';
import { getWorker, listWorkers } from './workers/registry.ts';

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
  const root = () => process.env.SC_PROJECT_ROOT ?? cwd;
  const parentId = 'CLANKER';
  const blink = new BlinkenState(650);
  let parentStatus = 'IDLE';
  let parentTool = '';

  let timer: NodeJS.Timeout | null = null;
  let fadeTimer: NodeJS.Timeout | null = null;
  let last = 0;
  function parentRow(): RackWorker {
    const m = uiCtx?.model;
    return {
      id: parentId,
      status: parentStatus,
      provider: m?.provider ?? '',
      model: m?.id ?? 'parent',
      role: 'operator',
      current_tool: parentTool,
      current_action: parentTool ? `tool: ${parentTool}` : '',
    };
  }
  function drawNow(): void {
    timer = null; last = Date.now();
    if (!uiCtx?.hasUI) return;
    try {
      uiCtx.ui.setWidget('sc-rack', renderRack(listWorkers(root()), process.stdout.columns || 80, blink, parentRow()));
    } catch { /* ctx stale */ }
  }
  function draw(): void {
    if (timer) return;
    timer = setTimeout(drawNow, Math.max(0, 140 - (Date.now() - last)));
    timer.unref();
  }
  function fadeLater(): void {
    if (fadeTimer) clearTimeout(fadeTimer);
    fadeTimer = setTimeout(() => { fadeTimer = null; draw(); }, blink.pulseMs + 40);
    fadeTimer.unref();
  }
  function see(id: string, ev: any): void {
    blink.ingest(id, ev);
    draw();
    fadeLater();
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
    m.on('event', (id: string, ev: any) => {
      blink.ingest(id, ev);
      if (ev?.type === 'extension_ui_request') {
        const t = String((ev?.method === 'notify' ? ev?.message : ev?.statusText) ?? '');
        if (t.startsWith('SC1 ')) blink.transfer(id, parentId);
      }
      draw();
      fadeLater();
    });
    m.on('exit', (id: string, x: any) => {
      if (!x?.expected) blink.pulse(id, 'ERR', Date.now(), 1200);
      draw();
      fadeLater();
    });
    mgr = m;
    return m;
  };

  pi.on('session_start', async (_e: any, ctx: any) => {
    cwd = ctx.cwd ?? cwd; uiCtx = ctx; first = true; parentStatus = 'IDLE'; parentTool = '';
    manager().recover();
    drawNow();
  });
  pi.on('session_shutdown', async () => {
    if (timer) clearTimeout(timer);
    if (fadeTimer) clearTimeout(fadeTimer);
    if (!mgr) return;
    for (const w of listWorkers(root())) { try { await mgr.runtime(w.id)?.stop(); } catch { /* */ } }
    mgr.releaseAll();
  });

  pi.on('agent_start', (ev: any) => { parentStatus = 'RUNNING'; see(parentId, ev); });
  pi.on('turn_start', (ev: any) => { parentStatus = 'RUNNING'; see(parentId, ev); });
  pi.on('message_start', (ev: any) => see(parentId, ev));
  pi.on('message_update', (ev: any) => see(parentId, ev));
  pi.on('message_end', (ev: any) => see(parentId, ev));
  pi.on('tool_execution_start', (ev: any) => { parentTool = String(ev?.toolName ?? ''); see(parentId, ev); });
  pi.on('tool_execution_update', (ev: any) => see(parentId, ev));
  pi.on('tool_execution_end', (ev: any) => { see(parentId, ev); parentTool = ''; });
  pi.on('turn_end', (ev: any) => see(parentId, ev));
  pi.on('agent_end', (ev: any) => { parentStatus = 'IDLE'; parentTool = ''; see(parentId, ev); });
  pi.on('before_agent_start', async (event: any) => {
    let extra = `${prompt('operator.md')}\n\n${prompt('authority.md')}`;
    if (first) { first = false; extra += `\n\n${reconstruct(root())}`; }
    return { systemPrompt: `${event.systemPrompt}\n\n${extra}` };
  });

  pi.registerTool({
    name: 'worker_spawn', label: 'Spawn Worker',
    description: 'Select a model by ability profile (never inherits yours), create task + worktree, spawn a worker. Non-blocking. Use dry_run to inspect the choice.',
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
      worktree_required: opt(Type.Boolean()), expected_outputs: strs(), context_hints: strs(),
    }),
    async execute(_id: string, p: any, _s: any, _u: any, ctx: any) {
      if (ctx) uiCtx = ctx;
      const r = await spawnSelected(manager(), catalog(), root(), p, {
        extensionPath: join(here, 'index.ts'), piCommand: process.execPath, args: process.argv[1] ? [process.argv[1]] : [],
        extraExtensions: parentExtensionArgs(process.argv, join(here, 'index.ts')),
        env: process.env.PI_CODING_AGENT_DIR ? { PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR } : {},
      });
      if (p.dry_run) {
        const s = r.selection ?? {};
        return txt(JSON.stringify({ dry_run: true, ok: r.ok, chosen: s.chosen?.key ?? null, reason: s.reason, ranked: s.ranked, excluded: s.excluded, error: r.error }, null, 1));
      }
      if (!r.ok) return txt(`error: ${r.error}`);
      if (r.worker_id) blink.transfer(parentId, r.worker_id);
      draw();
      fadeLater();
      return txt(JSON.stringify({ worker_id: r.worker_id, name: null, model: r.model, reason: r.selection?.reason, worktree: r.worktree, task_id: r.task_id }));
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
      return txt(line(w) + (w.worktree ? `\nworktree=${w.worktree.path} branch=${w.worktree.branch}` : '') + (r ? `\nresult: ${r.status} ${r.summary}` : ''));
    },
  });
  const act = (name: string, desc: string, fn: (id: string, text: string) => Promise<unknown>) =>
    pi.registerTool({
      name, label: name, description: desc, parameters: Type.Object({ id: Type.String(), text: Type.String() }),
      async execute(_i: string, p: any) {
        try {
          await fn(p.id, p.text);
          blink.transfer(parentId, p.id);
          draw();
          fadeLater();
          return txt('sent');
        } catch (e) { return txt(`error: ${(e as Error).message}`); }
      },
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
