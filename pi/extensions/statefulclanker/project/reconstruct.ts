import { listActiveIntent } from './intent.ts';
import { listTasks } from './tasks.ts';
import { listWorkers } from '../workers/registry.ts';

/** Compact text summary of durable project state for a cold-start operator. */
export function reconstruct(root: string): string {
  const L: string[] = ['## Project state (reconstructed)'];
  const none = (a: unknown[]) => { if (!a.length) L.push('  (none)'); };
  const intents = listActiveIntent(root);
  L.push('Active intent:'); none(intents);
  for (const i of intents) L.push(`  ${i.id}: ${i.statement}${i.scope ? ` [${i.scope}]` : ''}`);
  const tasks = listTasks(root);
  const active = tasks.filter((t) => t.status === 'active' || t.status === 'pending');
  const blocked = tasks.filter((t) => t.status === 'blocked');
  const done = tasks.filter((t) => t.status === 'complete' || t.status === 'failed').slice(-5);
  L.push('Active tasks:'); none(active);
  for (const t of active) L.push(`  ${t.id} ${t.status} ${t.title}${t.assigned_worker ? ` -> ${t.assigned_worker}` : ''}`);
  L.push('Blocked:'); none(blocked);
  for (const t of blocked) L.push(`  ${t.id} ${t.title}${t.unresolved.length ? ` : ${t.unresolved.join('; ')}` : ''}`);
  const workers = listWorkers(root);
  L.push('Workers:'); none(workers);
  for (const w of workers) L.push(`  ${w.id} ${w.status} ${w.provider}/${w.model} task=${w.task_id}${w.current_action ? ` "${w.current_action}"` : ''}`);
  L.push('Recent completed:'); none(done);
  for (const t of done) {
    const w = workers.find((x) => x.task_id === t.id);
    const r = w?.results[w.results.length - 1];
    L.push(`  ${t.id} ${t.status} ${t.title}${r ? ` : ${r.summary.slice(0, 160)}` : ''}`);
  }
  return L.join('\n');
}
