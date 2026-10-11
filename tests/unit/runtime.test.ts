import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Readable } from 'node:stream';
import { attachJsonlReader } from '../../workers/jsonl.ts';
import { deriveStatus, initialStatus } from '../../workers/status.ts';
import { WorkerManager, spawnSelected } from '../../workers/manager.ts';
import { CatalogService } from '../../catalog/service.ts';
import { listTasks } from '../../project/tasks.ts';
import { getWorker, listWorkers, upsertWorker } from '../../workers/registry.ts';

const here = dirname(fileURLToPath(import.meta.url));
const fake = join(here, '..', 'fixtures', 'fake-pi-rpc.mjs');

test('jsonl: U+2028 kept, CRLF stripped', async () => {
  const lines: string[] = [];
  const s = Readable.from(['{"a":"x y"}\r\n{"b"', ':2}\n{"c":3}']);
  attachJsonlReader(s, (l) => lines.push(l));
  await new Promise((r) => s.on('end', r));
  assert.deepEqual(lines, ['{"a":"x y"}', '{"b":2}', '{"c":3}']);
});

test('status reducer', () => {
  const s = deriveStatus(initialStatus, { type: 'tool_execution_start', toolName: 'bash' });
  assert.equal(s.status, 'RUNNING'); assert.equal(s.current_tool, 'bash');
  assert.equal(deriveStatus(s, { type: 'agent_end' }).status, 'IDLE');
  assert.equal(deriveStatus(s, { type: 'exit', code: 1 }).status, 'LOST');
  assert.equal(deriveStatus(s, { type: 'sc', payload: { kind: 'progress', status: 'BLOCKED' } }).status, 'BLOCKED');
  const f = deriveStatus(s, { type: 'sc', payload: { kind: 'finish' } });
  assert.equal(f.status, 'COMPLETE');
  assert.equal(deriveStatus(f, { type: 'agent_end' }).status, 'COMPLETE');
  assert.equal(deriveStatus(f, { type: 'exit', code: 0 }).status, 'COMPLETE');
});

test('manager spawn -> finish -> COMPLETE + receipt', async () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-mgr-'));
  const m = new WorkerManager(root);
  const got = new Promise<any>((res) => m.on('result', (id, r) => res({ id, r })));
  const id = await m.spawn({ taskId: 'T1', role: 'impl', provider: 'p', model: 'm', assignment: 'do it',
    extensionPath: 'ext.ts', piCommand: process.execPath, args: [fake] });
  const { r } = await got;
  assert.equal(r.summary, 'done: do it');
  await new Promise((r2) => setTimeout(r2, 100));
  assert.equal(getWorker(root, id)?.status, 'COMPLETE');
  const dir = join(root, '.statefulclanker', 'receipts', 'workers');
  assert.ok(readdirSync(dir).some((f) => f.startsWith(id + '-')));
  await m.retire(id);
  assert.equal(getWorker(root, id), null);
});

test('recover marks dead pid LOST', () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-rec-'));
  const m = new WorkerManager(root);
  upsertWorker(root, { id: 'W99', task_id: 't', role: 'r', ability_profile: 'r', provider: 'p', model: 'm', endpoint_lease: null,
    session_id: null, generation: 1, pid: 2147483000, status: 'RUNNING', project_root: root, worktree: null, started_at: '', last_activity: '',
    current_action: '', current_tool: '', context_usage: { tokens_used: 0, context_window: 0, percentage: 0, compactions: 0 },
    collaboration: { team_ids: [], inbox_cursor: 0, unread_count: 0 }, results: [] });
  assert.deepEqual(m.recover(), ['W99']);
  assert.equal(listWorkers(root)[0].status, 'LOST');
});

test('spawn failure after child launch retires the process and releases its lease', { timeout: 10000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-spawn-fail-'));
  const machineDir = mkdtempSync(join(tmpdir(), 'sc-spawn-machine-'));
  const model = { provider: 'test', id: 'free', name: 'Test', reasoning: false, input: ['text'],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 };
  const catalog = new CatalogService({ root, machineDir,
    getContext: () => ({ modelRegistry: { getAvailable: () => [model], getRegisteredProviderIds: () => ['test'] } }) });
  const manager = new WorkerManager(root, { catalog });
  let childPid: number | undefined;
  const originalSpawn = manager.spawn.bind(manager);
  manager.spawn = async spec => {
    // The assignment must be durable before the worker can read its task.
    assert.equal(listTasks(root)[0]?.assigned_worker, spec.workerId);
    try { return await originalSpawn(spec); }
    finally { childPid = manager.runtime(spec.workerId!)?.pid ?? undefined; }
  };
  try {
    const result = await spawnSelected(manager, catalog, root, { assignment: 'fail startup', model: 'test/free' },
      { extensionPath: 'unused.ts', piCommand: process.execPath, args: [fake], env: { FAKE_PROMPT_FAIL: '1' } });
    assert.equal(result.ok, false); assert.match(result.error!, /injected prompt failure/);
    assert.ok(childPid);
    assert.throws(() => process.kill(childPid!, 0), /ESRCH|no such process/i);
    assert.equal(manager.runtime('W01'), undefined);
    assert.equal(catalog.status('test/free').leases.used, 0);
    assert.equal(listWorkers(root).length, 0);
    assert.equal(listTasks(root)[0]?.status, 'failed');
    assert.match(listTasks(root)[0]?.unresolved[0] ?? '', /injected prompt failure/);
  } finally { await manager.retire('W01'); }
});
