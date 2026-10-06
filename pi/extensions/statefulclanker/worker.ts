import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { listActiveIntent } from './project/intent.ts';
import { getTask } from './project/tasks.ts';
import { CatalogService } from './catalog/service.ts';

const here = dirname(fileURLToPath(import.meta.url));
const prompt = (n: string) => readFileSync(join(here, 'prompts', n), 'utf8');
const txt = (s: string) => ({ content: [{ type: 'text' as const, text: s }], details: {} });
const strs = () => Type.Optional(Type.Array(Type.String()));

/**
 * Worker mode. Receipt ownership: the MANAGER writes the receipt + worker.completed event when it
 * receives the SC1 finish payload. The worker only emits "SC1 {json}" via ctx.ui.notify (no local write,
 * so no duplicates). Worker tool surface excludes spawn/intent tools.
 */
export function workerMode(pi: ExtensionAPI): void {
  const root = () => process.env.SC_PROJECT_ROOT ?? process.cwd();
  const emit = (ctx: any, payload: unknown) => ctx.ui.notify('SC1 ' + JSON.stringify(payload), 'info');

  pi.on('before_agent_start', async (event: any) => ({
    systemPrompt: `${event.systemPrompt}\n\n${prompt('worker.md')}\n\n${prompt('authority.md')}\n\nYou are worker ${process.env.SC_WORKER_ID}, task ${process.env.SC_TASK_ID}.`,
  }));

  pi.registerTool({
    name: 'task_context', label: 'Task Context',
    description: 'Return your task record and the active human intent.',
    parameters: Type.Object({}),
    async execute() {
      const t = process.env.SC_TASK_ID ? getTask(root(), process.env.SC_TASK_ID) : null;
      return txt(JSON.stringify({ task: t, intent: listActiveIntent(root()) }, null, 1));
    },
  });

  pi.registerTool({
    name: 'worker_progress', label: 'Worker Progress',
    description: 'Report status/current action/blocker to the operator.',
    parameters: Type.Object({
      status: Type.Optional(Type.String()), current_action: Type.Optional(Type.String()),
      blocker: Type.Optional(Type.String()), files: strs(),
    }),
    async execute(_id: string, p: any, _s: any, _u: any, ctx: any) {
      emit(ctx, { kind: 'progress', status: p.status, action: p.current_action, blocker: p.blocker, files: p.files ?? [] });
      return txt('progress sent');
    },
  });

  pi.registerTool({
    name: 'worker_finish', label: 'Worker Finish',
    description: 'Finish the task with a structured result. Required once work is done.',
    parameters: Type.Object({
      status: Type.String(), summary: Type.String(),
      changed_files: strs(), artifacts: strs(), tests_added: strs(), tests_run: strs(),
      test_results: Type.Optional(Type.Array(Type.Any())),
      important_discoveries: strs(), lessons_written: strs(), unresolved_questions: strs(), known_risks: strs(),
      collaboration_packets: Type.Optional(Type.Array(Type.Any())),
      confidence: Type.Optional(Type.Union([Type.String(), Type.Number()])),
    }),
    async execute(_id: string, p: any, _s: any, _u: any, ctx: any) {
      emit(ctx, { kind: 'finish', ...p });
      return txt('result submitted');
    },
  });

  const OUTCOMES = ['success', 'rate_limit', 'timeout', 'auth_error', 'malformed_tool_call', 'bad_continuation', 'tool_recovery', 'task_failure'];
  pi.registerTool({
    name: 'endpoint_report', label: 'Report Endpoint Outcome',
    description: 'Report an outcome for your own model (default) so selection can learn. Never include content or secrets.',
    parameters: Type.Object({
      model: Type.Optional(Type.String()), outcome: Type.String(),
      task_class: Type.Optional(Type.String()), note: Type.Optional(Type.String()),
    }),
    async execute(_id: string, p: any, _s: any, _u: any, ctx: any) {
      if (!OUTCOMES.includes(p.outcome)) return txt(`error: outcome must be one of ${OUTCOMES.join('|')}`);
      const own = ctx?.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
      const model = p.model ?? own;
      if (!model) return txt('error: model unknown');
      const svc = new CatalogService({ root: root(), getContext: () => ctx });
      const h = svc.reportOutcome(model, p.outcome, { task_class: p.task_class, note: p.note, worker_id: process.env.SC_WORKER_ID });
      return txt(`${model} ${h.state} streak=${h.failure_streak}`);
    },
  });
}
