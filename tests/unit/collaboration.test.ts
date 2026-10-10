import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  acceptProposal, claimPaths, closeSolicitation, hashFile, listCheckouts, listSolicitations,
  markNoticeDelivered, pendingNotices, proposeWrite, readSolicitation, recordSolicitationWorkerResult, rejectProposal,
  releasePaths, routeSolicitation, solicitProposals,
} from '../../workspace/checkouts.ts';
import { dispatchNotices, type CollaborationDispatch } from '../../workspace/dispatch.ts';

function repo(): string {
  const root = mkdtempSync(join(tmpdir(), 'sc-collaboration-'));
  const git = (...args: string[]) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' }).trim();
  git('init', '-q'); git('config', 'user.email', 'a@b'); git('config', 'user.name', 't');
  writeFileSync(join(root, 'file.ts'), 'start\n');
  git('add', '.'); git('commit', '-qm', 'initial');
  return root;
}
function mock() {
  const delivered: string[] = [], operator: string[] = [], spawned: string[] = [];
  let available = true;
  const deps: CollaborationDispatch = {
    async sendWorker(w, msg) { delivered.push(w + ': ' + msg); },
    notifyOperator(msg) { operator.push(msg); },
    canSpawn() { return available; },
    async spawn(q) { spawned.push(q.id); return { worker_id: 'W99' }; },
  };
  return { delivered, operator, spawned, deps, setAvailable(value: boolean) { available = value; } };
}

test('proposals notify their owner once and accepted/rejected outcomes notify authors', async () => {
  const root = repo(), m = mock();
  claimPaths(root, 'W01', ['file.ts']);
  const id = proposeWrite(root, 'W02', 'file.ts', hashFile(root, 'file.ts'), 'proposed\n');
  assert.equal(pendingNotices(root).length, 1);
  await dispatchNotices(root, m.deps);
  assert.match(m.delivered[0]!, /W01: Checkout proposal/);
  assert.match(m.delivered[0]!, new RegExp(id));
  assert.equal(await dispatchNotices(root, m.deps), 0);
  acceptProposal(root, 'W01', id);
  await dispatchNotices(root, m.deps);
  assert.match(m.delivered[1]!, /W02: Your proposal/);
  assert.match(m.delivered[1]!, /accepted/);
  assert.equal(pendingNotices(root).length, 0);
});

test('owner may reject and author receives a rejection packet', async () => {
  const root = repo(), m = mock();
  claimPaths(root, 'W01', ['file.ts']);
  const id = proposeWrite(root, 'W02', 'file.ts', hashFile(root, 'file.ts'), 'idea\n');
  await dispatchNotices(root, m.deps);
  rejectProposal(root, 'W01', id, 'does not meet requirement');
  await dispatchNotices(root, m.deps);
  assert.match(m.delivered.at(-1)!, /rejected/);
  assert.equal(readFileSync(join(root, 'file.ts'), 'utf8'), 'start\n');
});

test('solicitation to existing worker sends proposal-only instructions and holds checkout', async () => {
  const root = repo(), m = mock();
  claimPaths(root, 'W01', ['file.ts']);
  const q = solicitProposals(root, 'W01', ['file.ts'], 'Optimize parser', { target: 'W02' });
  assert.throws(() => releasePaths(root, 'W01', []), /outstanding collaboration/);
  await dispatchNotices(root, m.deps);
  assert.equal(readSolicitation(root, q.id).assigned_worker, 'W02');
  assert.match(m.delivered[0]!, /checkout_propose/);
  assert.match(m.delivered[0]!, /Do not claim, directly edit, or commit/);
  closeSolicitation(root, 'W01', q.id);
  releasePaths(root, 'W01', []);
  assert.equal(listCheckouts(root).claims.length, 0);
});

test('new helper request queues under capacity pressure, spawns just once, remains owner-controlled', async () => {
  const root = repo(), m = mock();
  claimPaths(root, 'W01', ['file.ts']);
  const q = solicitProposals(root, 'W01', ['file.ts'], 'Find a more efficient algorithm', { spawn_new: true });
  assert.throws(() => solicitProposals(root, 'W02', ['file.ts'], 'steal'), /only checkout owner/);
  m.setAvailable(false);
  assert.equal(await dispatchNotices(root, m.deps), 0);
  assert.equal(readSolicitation(root, q.id).status, 'pending');
  m.setAvailable(true);
  await dispatchNotices(root, m.deps);
  assert.equal(m.spawned.length, 1);
  assert.equal(readSolicitation(root, q.id).assigned_worker, 'W99');
  assert.equal(readSolicitation(root, q.id).status, 'assigned');
  await dispatchNotices(root, m.deps);
  assert.equal(m.spawned.length, 1);
  assert.equal(listSolicitations(root).length, 1);
});

test('unrouted request enters operator inbox and can be dispatched explicitly', async () => {
  const root = repo(), m = mock();
  claimPaths(root, 'W01', ['file.ts']);
  const q = solicitProposals(root, 'W01', ['file.ts'], 'Review readability');
  await dispatchNotices(root, m.deps);
  assert.equal(readSolicitation(root, q.id).status, 'routing');
  assert.match(m.operator[0]!, /checkout_dispatch/);
  routeSolicitation(root, q.id, 'W03');
  await dispatchNotices(root, m.deps);
  assert.match(m.delivered[0]!, /^W03: /);
  assert.equal(readSolicitation(root, q.id).assigned_worker, 'W03');
});

test('unavailable target returns to operator routing rather than swallowing request', async () => {
  const root = repo();
  claimPaths(root, 'W01', ['file.ts']);
  const q = solicitProposals(root, 'W01', ['file.ts'], 'Review file', { target: 'W02' });
  const operator: string[] = [];
  await dispatchNotices(root, {
    sendWorker: async () => { throw Error('worker offline'); },
    notifyOperator: (msg) => { operator.push(msg); },
    canSpawn: () => false,
    spawn: async () => { throw Error('should not spawn'); },
  });
  assert.equal(readSolicitation(root, q.id).status, 'routing');
  assert.match(operator[0]!, /checkout_dispatch/);
});

test('closed solicitation cannot be dispatched late', async () => {
  const root = repo(), m = mock();
  claimPaths(root, 'W01', ['file.ts']);
  const q = solicitProposals(root, 'W01', ['file.ts'], 'Review', { spawn_new: true });
  closeSolicitation(root, 'W01', q.id);
  await dispatchNotices(root, m.deps);
  assert.equal(m.spawned.length, 0);
  assert.equal(readSolicitation(root, q.id).status, 'closed');
});

test('finished proposal helper sends owner structured result without transferring ownership', async () => {
  const root = repo(), m = mock();
  claimPaths(root, 'W01', ['file.ts']);
  const q = solicitProposals(root, 'W01', ['file.ts'], 'Assess caching', { target: 'W02' });
  await dispatchNotices(root, m.deps);
  assert.deepEqual(recordSolicitationWorkerResult(root, 'W02', 'complete', 'Proposed cache invalidation'), [q.id]);
  await dispatchNotices(root, m.deps);
  assert.match(m.delivered.at(-1)!, /W01: Proposal helper W02 finished/);
  assert.match(m.delivered.at(-1)!, /Proposed cache invalidation/);
  assert.equal(listCheckouts(root).claims[0]!.owner, 'W01');
  assert.deepEqual(recordSolicitationWorkerResult(root, 'W02', 'complete', 'duplicate'), []);
});
