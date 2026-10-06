import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ensureLayout } from '../project/paths.ts';
import type { ScEvent } from './types.ts';

export function appendEvent(root: string, type: string, data: unknown): ScEvent {
  const base = ensureLayout(root);
  const ev: ScEvent = { ts: new Date().toISOString(), type, data };
  appendFileSync(join(base, 'events', 'event-log.jsonl'), JSON.stringify(ev) + '\n', 'utf8');
  return ev;
}

export function readEvents(root: string, opts: { since?: string; types?: string[] } = {}): ScEvent[] {
  const file = join(ensureLayout(root), 'events', 'event-log.jsonl');
  if (!existsSync(file)) return [];
  let evs = readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l) as ScEvent);
  const { since, types } = opts;
  if (since) evs = evs.filter((e) => e.ts >= since);
  if (types) evs = evs.filter((e) => types.includes(e.type));
  return evs;
}
