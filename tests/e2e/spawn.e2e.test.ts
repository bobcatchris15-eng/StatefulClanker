import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WorkerManager, spawnSelected } from '../../workers/manager.ts';
import { CatalogService } from '../../catalog/service.ts';
import { readFileSync } from 'node:fs';
import { getWorker } from '../../workers/registry.ts';
import { renderRack } from '../../ui/worker-rack.ts';
import { readEvents } from '../../protocol/events.ts';

const here = dirname(fileURLToPath(import.meta.url));
const ext = resolve(here, '..', '..', 'index.ts');
const mock = resolve(here, 'mock-provider-ext.ts');
const piPkgJson = join(dirname(fileURLToPath(import.meta.resolve('@earendil-works/pi-coding-agent'))), '..', 'package.json');
const piPkg = JSON.parse(readFileSync(piPkgJson, 'utf8'));
const binRel = typeof piPkg.bin === 'string' ? piPkg.bin : Object.values(piPkg.bin as Record<string, string>)[0];
const cli = resolve(dirname(piPkgJson), binRel);
const git = (cwd: string, ...a: string[]) => execFileSync('git', ['-C', cwd, ...a], { encoding: 'utf8' }).trim();

test('real pi worker with mock provider reaches COMPLETE', { timeout: 120000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-e2e-'));
  git(root, 'init', '-q');
  git(root, 'config', 'user.email', 't@t'); git(root, 'config', 'user.name', 't');
  writeFileSync(join(root, 'a.txt'), 'x\n');
  git(root, 'add', '.'); git(root, 'commit', '-qm', 'init');
  const agentDir = mkdtempSync(join(tmpdir(), 'sc-agent-'));
  const machine = mkdtempSync(join(tmpdir(), 'sc-machine-'));
  const model = { provider: 'scmock', id: 'scmock-1', name: 'SC Mock', reasoning: false, input: ['text'],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8000, maxTokens: 1000 };
  const catalog = new CatalogService({
    root, machineDir: machine, 
    getContext: () => ({ modelRegistry: { getAvailable: () => [model], getRegisteredProviderIds: () => ['scmock'] } }),
  });
  const m = new WorkerManager(root, { catalog });
  const done = new Promise<any>((res, rej) => {
    m.on('result', (_id, r) => res(r));
    setTimeout(() => rej(new Error('timeout waiting for result')), 90000).unref();
  });
  const sp = await spawnSelected(m, catalog, root, { assignment: 'do the mock work', task_title: 'mock', ability_profile: 'fast' }, {
    extensionPath: ext, piCommand: process.execPath, args: [cli, '-e', mock],
    env: { PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: '1', SC_MACHINE_DIR: machine },
  });
  assert.equal(sp.ok, true, sp.error);
  const id = sp.worker_id!;
  assert.equal(sp.workspace, root);
  assert.equal(sp.checkout_conflicts?.length, 0);
  const receipt = JSON.parse(readFileSync(sp.receipt!, 'utf8'));
  assert.equal(receipt.selection.chosen.key, 'scmock/scmock-1');
  assert.match(receipt.selection.reason, /chose scmock\/scmock-1/);
  assert.equal(receipt.lease.model, 'scmock/scmock-1');
  assert.equal(catalog.status('scmock/scmock-1').leases.used, 1);
  const rd = m.runtime(id)!;
  let err = '';
  rd.on('stderr', (s: string) => { err += s; });
  try {
    const r = await done;
    assert.equal(r.summary, 'mock work done');
    const w = getWorker(root, id)!;
    assert.equal(w.status, 'COMPLETE');
    assert.equal(w.display_name, 'Rivet');
    const rack = renderRack([{ ...(w as any), task_title: 'e2e spawn task' }], 80);
    assert.match(rack[1]!, /W\d\d Rivet/, 'supervisor panel row shows id and display name');
    assert.match(rack[1]!, /e2e spawn task/);
    assert.ok(readEvents(root, { types: ['worker.named'] }).length >= 1);
    const receipts = readdirSync(join(root, '.statefulclanker', 'receipts', 'workers'));
    assert.equal(receipts.length, 1);
    assert.equal(catalog.status('scmock/scmock-1').leases.used, 0, 'lease released after COMPLETE');
    assert.ok(readEvents(root, { types: ['worker.completed'] }).length >= 1);
    assert.equal(w.worktree, null);
    assert.equal(git(root, 'branch', '--list', 'clanker/*'), '');
  } catch (e) {
    throw new Error(`${(e as Error).message}\nstderr: ${err.slice(0, 1500)}`);
  } finally {
    await m.retire(id);
  }
});
