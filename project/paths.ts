import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

export function scDir(root: string): string {
  return join(root, '.statefulclanker');
}

export function ensureLayout(root: string): string {
  const base = scDir(root);
  for (const d of [
    'intent/history', 'tasks/active', 'tasks/complete', 'tasks/cancelled',
    'workers/history', 'receipts/workers', 'events', 'context/receipts',
  ]) mkdirSync(join(base, d), { recursive: true });
  return base;
}
