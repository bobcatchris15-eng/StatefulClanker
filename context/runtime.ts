/** Non-destructive, silent per-inference context recompilation for Pi >= 0.87. */
import { join } from 'node:path';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { getTask, listTasks } from '../project/tasks.ts';
import { listActiveIntent } from '../project/intent.ts';
import { writeJsonAtomic } from '../protocol/persistence.ts';
import { ensureLayout } from '../project/paths.ts';
import { selectKnowledge } from './knowledge.ts';

function limit(raw: string | undefined, fallback: number): number {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.max(8000, Math.min(120000, n)) : fallback;
}
const size = (x: unknown) => JSON.stringify(x).length;
/** Preserve initial assignment and the recent coherent transcript. No persisted history is deleted. */
export function projectHistory<T extends { role: string }>(messages: T[], budget = 26000): T[] {
  if (messages.length < 5 || size(messages) <= budget) return messages;
  let cut = messages.length - 1, cost = 0;
  for (let i = messages.length - 1; i >= 0; i--) {
    const next = size(messages[i]);
    if (cost + next > budget && i < messages.length - 5) break;
    cost += next; cut = i;
  }
  // Do not begin with an orphaned tool result. Include its initiating assistant tool call.
  while (cut > 0 && messages[cut]?.role === 'toolResult') cut--;
  // Never drop the initial assignment, even when much of the intervening transcript is dropped.
  const firstUser = messages.findIndex(m => m.role === 'user');
  const pinned = firstUser >= 0 && firstUser < cut ? [messages[firstUser]!] : [];
  // Preserve recent steering from a parent/human. Older tool outputs are disposable.
  const recentUser = messages.slice(firstUser + 1, cut).filter(m => m.role === 'user').slice(-3);
  return [...pinned, ...recentUser, ...messages.slice(cut)];
}
export function registerLivingContext(pi: ExtensionAPI, root: () => string, actor: () => string): void {
  let lastFingerprint = '';
  pi.on('session_start', () => { lastFingerprint = ''; });
  pi.on('context', async (event: any) => ({
    messages: projectHistory(event.messages, limit(process.env.SC_CONTEXT_HISTORY_CHARS, 26000)),
  }));
  pi.on('context_with_system', async (event: any) => {
    const messages = event.messages;
    if (!messages?.length || messages[0]?.role !== 'system') return;
    const project = root();
    const taskId = process.env.SC_TASK_ID;
    const task = taskId ? getTask(project, taskId) : undefined;
    const intent = listActiveIntent(project);
    const active = task ? [] : listTasks(project).filter(t => t.status === 'active').slice(0, 8);
    const query = [
      task?.title, task?.objective, ...(task?.context_hints ?? []),
      ...intent.map(i => i.statement), ...active.map(t => t.title),
    ].filter(Boolean).join(' ').slice(0, 5000);
    const paths = task?.scope.files ?? [];
    const selected = selectKnowledge(project, query, paths);
    const taskContext = task ? '## Current task\n' + task.id + ': ' + task.title + '\n' + task.objective : '';
    const living = [selected.text, taskContext].filter(Boolean).join('\n\n');
    if (selected.fingerprint !== lastFingerprint) {
      try {
        writeJsonAtomic(join(ensureLayout(project), 'context', 'receipts', 'latest-' + actor() + '.json'), {
          actor: actor(), task_id: task?.id ?? null, compiled_at: new Date().toISOString(),
          fingerprint: selected.fingerprint, sources: selected.sources,
          token_estimate: Math.ceil(living.length / 4),
        });
        lastFingerprint = selected.fingerprint;
      } catch { /* context projection must never block model inference */ }
    }
    const head = messages[0];
    // Sections maintain Pi's tool declarations and stable cacheable prompt prefix.
    const sections = { ...(head.sections ?? {}), 'statefulclanker-living-context': living };
    return { messages: [{ ...head, sections }, ...messages.slice(1)] };
  });
}
