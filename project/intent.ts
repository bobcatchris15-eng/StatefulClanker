import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { appendEvent } from '../protocol/events.ts';
import { readJson, writeJsonAtomic } from '../protocol/persistence.ts';
import type { Intent, IntentStatus } from '../protocol/types.ts';
import { ensureLayout } from './paths.ts';

function histDir(root: string): string { return join(ensureLayout(root), 'intent', 'history'); }

function listAll(root: string): Intent[] {
  const d = histDir(root);
  return readdirSync(d).filter((f) => f.endsWith('.json')).map((f) => readJson<Intent>(join(d, f), null as never));
}

function refreshCurrent(root: string): void {
  const active = listAll(root).filter((i) => i.status === 'active').sort((a, b) => a.id.localeCompare(b.id));
  writeJsonAtomic(join(ensureLayout(root), 'intent', 'current.json'), active);
}

export function recordIntent(
  root: string,
  p: { statement: string; source: string; scope: string; supersedes?: string[] },
): Intent {
  const all = listAll(root);
  const n = all.reduce((m, i) => Math.max(m, parseInt(i.id.replace(/^i-/, ''), 10) || 0), 0) + 1;
  const supersedes = p.supersedes ?? [];
  for (const sid of supersedes) {
    const old = all.find((i) => i.id === sid);
    if (old) writeJsonAtomic(join(histDir(root), `${sid}.json`), { ...old, status: 'superseded' });
  }
  const intent: Intent = {
    id: `i-${String(n).padStart(4, '0')}`,
    timestamp: new Date().toISOString(),
    source: p.source,
    statement: p.statement,
    supersedes,
    scope: p.scope,
    status: 'active',
  };
  writeJsonAtomic(join(histDir(root), `${intent.id}.json`), intent);
  refreshCurrent(root);
  appendEvent(root, 'intent.changed', { id: intent.id, supersedes });
  return intent;
}

export function listActiveIntent(root: string): Intent[] {
  return listAll(root).filter((i) => i.status === 'active').sort((a, b) => a.id.localeCompare(b.id));
}

export function setIntentStatus(root: string, id: string, status: IntentStatus): Intent | null {
  const cur = listAll(root).find((i) => i.id === id);
  if (!cur) return null;
  const next = { ...cur, status };
  writeJsonAtomic(join(histDir(root), `${id}.json`), next);
  refreshCurrent(root);
  appendEvent(root, 'intent.changed', { id, status });
  return next;
}
