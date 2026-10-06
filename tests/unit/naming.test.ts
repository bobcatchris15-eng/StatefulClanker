import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { sanitizeName, uniqueName, WorkerManager } from '../../workers/manager.ts';
import { getWorker, upsertWorker } from '../../workers/registry.ts';
import { initialStatus } from '../../workers/status.ts';
import type { Worker } from '../../protocol/types.ts';

const mk = (id: string, status: Worker['status'] = 'RUNNING', display_name?: string): Worker => ({
  id, ...(display_name ? { display_name } : {}), task_id: 't', role: 'worker', ability_profile: 'fast', provider: 'p', model: 'm',
  endpoint_lease: null, session_id: null, generation: 1, pid: null, status, project_root: '', worktree: null,
  started_at: '', last_activity: '', current_action: '', current_tool: '',
  context_usage: { tokens_used: 0, context_window: 0, percentage: 0, compactions: 0 },
  collaboration: { team_ids: [], inbox_cursor: 0, unread_count: 0 }, results: [],
});

test('sanitize', () => {
  assert.equal(sanitizeName('  Rivet\n[x] '), 'Rivet x');
  assert.equal(sanitizeName('a'.repeat(40)).length, 20);
  assert.equal(sanitizeName('\n\t[]'), '');
  assert.equal(sanitizeName(undefined), '');
});

test('dedupe case-insensitive', () => {
  assert.equal(uniqueName('Rivet', ['rivet']), 'Rivet-2');
  assert.equal(uniqueName('Rivet', ['rivet', 'Rivet-2']), 'Rivet-3');
  assert.equal(uniqueName('Zed', ['rivet']), 'Zed');
  assert.ok(uniqueName('a'.repeat(20), ['a'.repeat(20)]).length <= 20);
});

test('fixed after first; dedupes against active only', () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-name-'));
  const m = new WorkerManager(root);
  upsertWorker(root, mk('W01', 'RUNNING', 'Rivet'));
  upsertWorker(root, mk('W02', 'COMPLETE', 'Old'));
  upsertWorker(root, mk('W03'));
  const e: any = { st: { ...initialStatus }, lastEvent: 0, waiting: false };
  (m as any).onSc('W03', e, { kind: 'name', name: 'rivet' });
  assert.equal(getWorker(root, 'W03')!.display_name, 'rivet-2');
  (m as any).onSc('W03', e, { kind: 'name', name: 'Other' });
  assert.equal(getWorker(root, 'W03')!.display_name, 'rivet-2');
  upsertWorker(root, mk('W04'));
  (m as any).onSc('W04', e, { kind: 'name', name: 'Old' });
  assert.equal(getWorker(root, 'W04')!.display_name, 'Old');
});
