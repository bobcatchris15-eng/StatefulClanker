import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WorkerManager } from '../../workers/manager.ts';
import { getWorker } from '../../workers/registry.ts';
import { readEvents } from '../../protocol/events.ts';
import { createTask } from '../../project/tasks.ts';
import { createWorktree } from '../../worktrees/create.ts';

const here = dirname(fileURLToPath(import.meta.url));
const ext = resolve(here, '..', '..', 'index.ts');
const mock = resolve(here, 'mock-provider-ext.ts');
const rt = resolve(here, '..', '..', '..', '..', '..', 'install', 'pi-runtime');
const cli = join(rt, 'node_modules', '@earendil-works', 'pi-coding-agent', 'dist', 'cli.js');
const git = (cwd: string, ...a: string[]) => execFileSync('git', ['-C', cwd, ...a], { encoding: 'utf8' }).trim();

test('real pi worker with mock provider reaches COMPLETE', { timeout: 120000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-e2e-'));
  git(root, 'init', '-q');
  git(root, 'config', 'user.email', 't@t'); git(root, 'config', 'user.name', 't');
  writeFileSync(join(root, 'a.txt'), 'x\n');
  git(root, 'add', '.'); git(root, 'commit', '-qm', 'init');
  const task = createTask(root, { title: 'mock', objective: 'do mock work', status: 'active' });
  const wt = createWorktree(root, task.id, 'mock');
  const agentDir = mkdtempSync(join(tmpdir(), 'sc-agent-'));
  const m = new WorkerManager(root);
  const done = new Promise<any>((res, rej) => {
    m.on('result', (_id, r) => res(r));
    setTimeout(() => rej(new Error('timeout waiting for result')), 90000).unref();
  });
  const id = await m.spawn({
    taskId: task.id, role: 'worker', provider: 'scmock', model: 'scmock-1', assignment: 'do the mock work', worktree: wt,
    extensionPath: ext, piCommand: process.execPath, args: [cli, '-e', mock],
    env: { PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: '1' },
  });
  const rd = m.runtime(id)!;
  let err = '';
  rd.on('stderr', (s: string) => { err += s; });
  try {
    const r = await done;
    assert.equal(r.summary, 'mock work done');
    const w = getWorker(root, id)!;
    assert.equal(w.status, 'COMPLETE');
    const receipts = readdirSync(join(root, '.statefulclanker', 'receipts', 'workers'));
    assert.equal(receipts.length, 1);
    assert.ok(readEvents(root, { types: ['worker.completed'] }).length >= 1);
    assert.ok(existsSync(wt.path));
    assert.match(git(root, 'branch', '--list', wt.branch), /clanker/);
  } catch (e) {
    throw new Error(`${(e as Error).message}\nstderr: ${err.slice(0, 1500)}`);
  } finally {
    await m.retire(id);
  }
});
