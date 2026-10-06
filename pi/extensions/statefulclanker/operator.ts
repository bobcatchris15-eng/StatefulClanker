import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { recordIntent } from './project/intent.ts';
import { reconstruct } from './project/reconstruct.ts';
import { createTask, getTask, listTasks, updateTask } from './project/tasks.ts';
import { renderRack } from './ui/worker-rack.ts';
import { createWorktree } from './worktrees/create.ts';
import { WorkerManager } from './workers/manager.ts';
import { getWorker, listWorkers } from './workers/registry.ts';

const here = dirname(fileURLToPath(import.meta.url));
const prompt = (n: string) => readFileSync(join(here, 'prompts', n), 'utf8');
const txt = (s: string) => ({ content: [{ type: 'text' as const, text: s }], details: {} });
const opt = (t: any) => Type.Optional(t);
const strs = () => Type.Optional(Type.Array(Type.String()));

function slugify(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || 'task';
}

export function operatorMode(pi: ExtensionAPI): void {
  let cwd = process.cwd();
  let uiCtx: any = null;
  let mgr: WorkerManager | null = null;
  let first = true;
  const root = () => process.env.SC_PROJECT_ROOT ?? cwd;

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

  const manager = (): WorkerManager => {
    if (mgr) return mgr;
    const m = new WorkerManager(root());
    m.on('result', (id: string, r: any, file: string) => {
      const files = r.changed_files?.length ? ` files=${r.changed_files.join(',')}` : '';
      const unres = r.unresolved_questions?.length ? `\nunresolved: ${r.unresolved_questions.join('; ')}` : '';
      const risks = r.known_risks?.length ? `\nrisks: ${r.known_risks.join('; ')}` : '';
      pi.sendMessage({
        customType: 'sc-worker-result', display: true, details: { worker: id, task: r.task_id, receipt: file },
        content: `Worker ${id} finished task ${r.task_id}: ${r.status}\n${r.summary}${files}${unres}${risks}`,
      }, { deliverAs: 'followUp', triggerTurn: true });
      draw();
    });
    m.on('event', draw);
    m.on('exit', draw);
    mgr = m;
    return m;
  };

  pi.on('session_start', async (_e: any, ctx: any) => {
    cwd = ctx.cwd ?? cwd; uiCtx = ctx; first = true;
    manager().recover();
    drawNow();
  });
  pi.on('session_shutdown', async () => {
    if (!mgr) return;
    for (const w of listWorkers(root())) { try { await mgr.runtime(w.id)?.stop(); } catch { /* */ } }
  });
  pi.on('before_agent_start', async (event: any) => {
    let extra = `${prompt('operator.md')}\n\n${prompt('authority.md')}`;
    if (first) { first = false; extra += `\n\n${reconstruct(root())}`; }
    return { systemPrompt: `${event.systemPrompt}\n\n${extra}` };
  });

  pi.registerTool({
    name: 'worker_spawn', label: 'Spawn Worker',
    description: 'Create a task + worktree and spawn a worker pi process. Non-blocking; result arrives later.',
    parameters: Type.Object({
      assignment: Type.String(), provider: Type.String(), model: Type.String(),
      role: opt(Type.String()), task_title: opt(Type.String()), files: strs(),
      worktree_required: opt(Type.Boolean()), expected_outputs: strs(), context_hints: strs(),
    }),
    async execute(_id: string, p: any) {
      const r = root();
      const task = createTask(r, {
        title: p.task_title ?? p.assignment.slice(0, 60), objective: p.assignment, status: 'active',
        scope: { files: p.files ?? [], subsystem: '', worktree: '' },
        expected_outputs: p.expected_outputs ?? [], context_hints: p.context_hints ?? [],
      });
      // worker id is allocated inside manager.spawn, so the worktree dir/branch is keyed by task id.
      const worktree = p.worktree_required === false ? undefined : createWorktree(r, task.id, slugify(p.task_title ?? p.assignment));
      const id = await manager().spawn({
        taskId: task.id, role: p.role ?? 'worker', provider: p.provider, model: p.model, assignment: p.assignment,
        worktree, extensionPath: join(here, 'index.ts'),
        piCommand: process.execPath, args: process.argv[1] ? [process.argv[1]] : [],
      });
      updateTask(r, task.id, { assigned_worker: id, scope: { ...task.scope, worktree: worktree?.path ?? '' } });
      draw();
      return txt(JSON.stringify({ worker_id: id, provider: p.provider, model: p.model, worktree: worktree?.path ?? null, task_id: task.id }));
    },
  });

  const line = (w: any) => `${w.id} ${w.status} ${w.provider}/${w.model} task=${w.task_id}${w.current_action ? ` "${w.current_action}"` : ''}`;
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
