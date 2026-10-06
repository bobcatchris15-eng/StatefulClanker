import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CatalogService } from '../../catalog/service.ts';
import { buildPool } from '../../catalog/pool.ts';
import { classifyErrorText, providerSignal, parentExtensionArgs } from '../../workers/runtime.ts';

const paid = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 };
const free = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
const mk = (provider: string, id: string, cost = paid) =>
  ({ provider, id, name: id, reasoning: false, input: ['text'], cost, contextWindow: 200000, maxTokens: 8000 });

function setup(opts: { scoped?: any[]; noAuth?: string[]; extProviders?: string[]; allow?: string[] } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'sc-svc-m-'));
  const root = mkdtempSync(join(tmpdir(), 'sc-svc-r-'));
  writeFileSync(join(dir, 'profiles.json'), JSON.stringify({
    'p1/*': { capabilities: { coding: 'good', tool_use: 'good' } },
    'p2/*': { capabilities: { coding: 'fair', tool_use: 'fair' } },
    'ext/*': { capabilities: { coding: 'poor', tool_use: 'poor' } },
  }));
  const models = [mk('p1', 'big'), mk('p2', 'free', free), mk('ext', 'only')];
  const registry = {
    getAvailable: () => models,
    find: (p: string, id: string) => models.find((m) => m.provider === p && m.id === id),
    hasConfiguredAuth: (m: any) => !(opts.noAuth ?? []).includes(m.provider),
    getRegisteredProviderIds: () => opts.extProviders ?? ['ext'],
  };
  let now = 1_000_000;
  const svc = new CatalogService({
    root, machineDir: dir, pid: 4242, isAlive: () => false, now: () => now,
    getContext: () => ({ modelRegistry: registry, scopedModels: opts.scoped, model: models[0] }),
  });
  return { svc, dir, root, advance: (ms: number) => { now += ms; } };
}

test('parentExtensionArgs: three forms, absolute, deduped, self excluded', () => {
  const cwd = process.cwd();
  const r = parentExtensionArgs(['node', 'pi', '-e', 'a.ts', '--extension', 'b.ts', '--extension=c.ts', '-e', './a.ts', '-e', 'self/index.ts'], 'self/index.ts');
  assert.deepEqual(r, [join(cwd, 'a.ts'), join(cwd, 'b.ts'), join(cwd, 'c.ts')]);
});

test('pool: registered providers not excluded; scoped intersects', () => {
  const { svc } = setup();
  const p = svc.pool();
  assert.deepEqual(p.candidates.map((c) => c.key).sort(), ['ext/only', 'p1/big', 'p2/free']);
  assert.equal(p.excluded.length, 0);
  const reg = { getAvailable: () => [mk('p1', 'big'), mk('p2', 'free', free)] };
  const s = buildPool({ modelRegistry: reg, scopedModels: [{ model: mk('p2', 'free') }] });
  assert.deepEqual(s.candidates.map((c) => c.key), ['p2/free']);
  assert.ok(s.excluded.some((e) => e.key === 'p1/big' && /scoped/.test(e.why)));
});

test('resolve selects best by profile, never from parent implicitly; excluded listed', () => {
  const { svc } = setup();
  const r = svc.resolve({ profile: 'implementation' });
  assert.equal(r.ok, true);
  assert.equal(r.chosen!.key, 'p1/big');
  assert.match(r.reason, /chose p1\/big/);
  const none = svc.resolve({ profile: 'implementation', free_only: true, avoid_provider: ['p2'] });
  assert.equal(none.ok, false);
  assert.match(none.error!, /p2\/free/);
});

test('explicit validation failures and success', () => {
  const { svc } = setup({ noAuth: ['p2'] });
  assert.match(svc.resolve({}, { explicit: 'nope' }).error!, /provider\/id/);
  assert.match(svc.resolve({}, { explicit: 'p9/x' }).error!, /not found/);
  assert.match(svc.resolve({}, { explicit: 'p2/free' }).error!, /auth/);
  const ok = svc.resolve({}, { explicit: 'p1/big' });
  assert.equal(ok.ok, true); assert.equal(ok.reason, 'explicit'); assert.equal(ok.chosen!.provider, 'p1');
  svc.reportOutcome('p1/big', 'rate_limit');
  assert.match(svc.resolve({}, { explicit: 'p1/big' }).error!, /cooling/);
});

test('lease lifecycle: capacity 1 for free, release frees, recover reaps dead pid', () => {
  const { svc } = setup();
  const l1 = svc.claimLease('p2/free', 'W01');
  assert.ok(l1);
  assert.equal(svc.claimLease('p2/free', 'W02'), null);
  assert.match(svc.resolve({}, { explicit: 'p2/free' }).error!, /lease full/);
  assert.ok(svc.resolve({ profile: 'implementation' }).excluded.some((e) => e.key === 'p2/free' && /lease full/.test(e.why)));
  assert.equal(svc.releaseWorker('W01'), 1);
  assert.ok(svc.claimLease('p2/free', 'W03'));
  assert.equal(svc.status('p2/free').leases.used, 1);
  assert.equal(svc.recover(), 1); // isAlive=false -> parent dead
  assert.equal(svc.status('p2/free').leases.used, 0);
});

test('outcome -> health cooldown excludes model from next selection, success clears', () => {
  const { svc, advance } = setup();
  assert.equal(svc.resolve({ profile: 'implementation' }).chosen!.key, 'p1/big');
  svc.reportOutcome('p1/big', 'rate_limit', { worker_id: 'W01' });
  const r = svc.resolve({ profile: 'implementation' });
  assert.equal(r.chosen!.key, 'p2/free');
  assert.ok(r.excluded.some((e) => e.key === 'p1/big' && /cooling/.test(e.why)));
  advance(3_600_000);
  assert.equal(svc.resolve({ profile: 'implementation' }).chosen!.key, 'p1/big');
});

test('provider signal classification (no content kept)', () => {
  assert.equal(classifyErrorText('429 Too Many Requests'), 'rate_limit');
  assert.equal(classifyErrorText('401 unauthorized'), 'auth_error');
  assert.equal(classifyErrorText('request timeout'), 'timeout');
  assert.deepEqual(providerSignal({ type: 'auto_retry_end', success: false, finalError: '529 overloaded' }), { outcome: 'rate_limit', source: 'retry' });
  assert.equal(providerSignal({ type: 'auto_retry_end', success: true }), null);
  assert.deepEqual(providerSignal({ type: 'agent_end', willRetry: false, messages: [{ role: 'assistant', stopReason: 'error', errorMessage: '403 forbidden' }] }),
    { outcome: 'auth_error', source: 'agent_end' });
  assert.equal(providerSignal({ type: 'agent_end', willRetry: true, messages: [{ role: 'assistant', stopReason: 'error', errorMessage: '429' }] }), null);
  assert.equal(providerSignal({ type: 'agent_end', messages: [{ role: 'assistant', stopReason: 'stop' }] }), null);
});
