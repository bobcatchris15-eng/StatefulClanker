import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { watch, initializeTaskInterest, pendingRelevant, markRelevantDelivered } from '../../context/subscriptions.ts';
import { claimPaths, publish } from '../../workspace/checkouts.ts';
import { reserveWorkerId, releaseWorkerReservation } from '../../workers/registry.ts';

test('checkout publication routes only relevant commits and does not force another model call', () => {
  const root=mkdtempSync(join(tmpdir(),'sc-subs-'));
  const git=(...args:string[])=>execFileSync('git',['-C',root,...args]);
  git('init','-q');git('config','user.name','tester');git('config','user.email','t@t');
  mkdirSync(join(root,'.clanker','knowledge'),{recursive:true});
  writeFileSync(join(root,'.clanker','knowledge','plants.md'),'# Plants\nOld.\n');
  git('add','.');git('commit','-qm','initial');
  initializeTaskInterest(root,'W01',{paths:['renderer/'],task:'vegetation renderer'});
  watch(root,'W02',{topics:['database']});
  watch(root,'W03',{topics:['plants']});
  claimPaths(root,'W03',['.clanker/knowledge/plants.md']);
  writeFileSync(join(root,'.clanker','knowledge','plants.md'),
    '---\ntags: [vegetation]\n---\n# Plants\nObserved large geometry.\n');
  const commit=publish(root,'W03',['.clanker/knowledge/plants.md'],'knowledge change');
  const a=pendingRelevant(root,'W01');
  assert.equal(a.length,1);assert.equal(a[0]?.commit,commit);
  assert.equal(pendingRelevant(root,'W02').length,0);
  assert.equal(pendingRelevant(root,'W03').length,0);
  markRelevantDelivered(root,'W01',[a[0]!.id]);
  assert.equal(pendingRelevant(root,'W01').length,0);
});
test('global worker reservations enforce the cap before process launch',()=>{
  const root=mkdtempSync(join(tmpdir(),'sc-reserve-'));
  const ids=[reserveWorkerId(root),reserveWorkerId(root),reserveWorkerId(root)];
  assert.deepEqual(ids,['W01','W02','W03']);
  assert.throws(()=>reserveWorkerId(root),/capacity/);
  releaseWorkerReservation(root,ids[1]!);
  assert.equal(reserveWorkerId(root),'W04');
});
