import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ensureFoundation, knowledgeGraph, listKnowledge, selectKnowledge } from '../../context/knowledge.ts';
import { projectHistory, registerLivingContext } from '../../context/runtime.ts';
import { updateKnowledge } from '../../context/tools.ts';
import { claimPaths, listCheckouts } from '../../workspace/checkouts.ts';

function repo(): string {
  const root = mkdtempSync(join(tmpdir(), 'sc-knowledge-'));
  const git = (...a: string[]) => execFileSync('git', ['-C', root, ...a], { encoding: 'utf8' }).trim();
  git('init', '-q'); git('config', 'user.email', 't@t'); git('config', 'user.name', 't');
  writeFileSync(join(root, 'README.md'), 'hello\n');
  git('add', '.'); git('commit', '-qm', 'initial');
  return root;
}
test('shared foundation is seeded and included for unrelated tasks', () => {
  const root = repo();
  ensureFoundation(root);
  const a = selectKnowledge(root, 'a completely unrelated task');
  assert.match(a.text, /Living Clanker foundation/);
  assert.ok(a.sources.some(x => x.path === '.clanker/foundation.md'));
});
test('path/keyword selection and graph link resolution change with Markdown revisions', () => {
  const root = repo();
  mkdirSync(join(root, '.clanker', 'knowledge'), { recursive: true });
  const one = '---\nid: checkout\nstatus: verified\npaths: [workspace/checkouts.ts]\nlinks: [verification]\n---\n# Checkout\nStrict file ownership and publish.\n';
  writeFileSync(join(root, '.clanker', 'knowledge', 'checkout.md'), one);
  writeFileSync(join(root, '.clanker', 'knowledge', 'verification.md'), '# Verification\nCheck the test assertions.\n');
  const before = selectKnowledge(root, 'publish', ['workspace/checkouts.ts']);
  assert.ok(before.sources.some(x => x.path.endsWith('checkout.md')));
  assert.ok(before.sources.some(x => x.path.endsWith('verification.md')));
  assert.deepEqual(knowledgeGraph(listKnowledge(root)).edges, [['.clanker/knowledge/checkout.md', '.clanker/knowledge/verification.md']]);
  writeFileSync(join(root, '.clanker', 'knowledge', 'checkout.md'), one + '\nBetter locking approach.\n');
  assert.notEqual(selectKnowledge(root, 'publish', ['workspace/checkouts.ts']).fingerprint, before.fingerprint);
});
test('effective history is bounded without mutating stored messages', () => {
  const first = { role: 'user', content: 'Implement parser' };
  const messages: { role: string; content: string }[] = [first];
  for (let i = 0; i < 20; i++) {
    messages.push({ role: 'assistant', content: 'a'.repeat(3000) });
    messages.push({ role: 'toolResult', content: 'b'.repeat(3000) });
  }
  const projection = projectHistory(messages, 9000);
  assert.equal(projection[0], first);
  assert.ok(projection.length < messages.length);
  assert.equal(projection[1]?.role, 'assistant');
  assert.equal(messages.length, 41);
});
test('memory updates use checkout publication and stale writes are rejected', () => {
  const root = repo(), path = '.clanker/knowledge/new.md';
  const made = updateKnowledge(root, 'W01', path, '# Knowledge\nVerified result\n', null);
  assert.ok(made.commit);
  assert.ok(made.hash);
  assert.throws(() => updateKnowledge(root, 'W02', path, '# Stale', null), /stale/);
  claimPaths(root, 'W01', [path]);
  const proposal = updateKnowledge(root, 'W02', path, '# Proposed update\n', made.hash!);
  assert.ok(proposal.proposal_id);
  assert.equal(listCheckouts(root).proposals.length, 1);
});

test('per-inference hook silently replaces living foundation without mutating session messages', async () => {
  const root = repo();
  const handlers: Record<string, (e: any) => any> = {};
  registerLivingContext({ on(name: string, fn: (e: any) => any) { handlers[name] = fn; } } as any,
    () => root, () => 'W01');
  const original = [{ role: 'system', content: 'stable', timestamp: 1,
    sections: { stable: 'keep' }, toolsAdded: [{ name: 'test' }] },
    { role: 'user', content: 'work', timestamp: 2 }];
  const first = await handlers['context_with_system']!({ messages: original });
  assert.match(first.messages[0].sections['statefulclanker-living-context'], /Living Clanker foundation/);
  assert.equal(first.messages[0].sections.stable, 'keep');
  assert.deepEqual(first.messages[0].toolsAdded, original[0]!.toolsAdded);
  assert.deepEqual(original[0]!.sections, { stable: 'keep' });
  writeFileSync(join(root, '.clanker', 'foundation.md'), '# New foundation\nA new shared procedure.\n');
  const next = await handlers['context_with_system']!({ messages: original });
  assert.match(next.messages[0].sections['statefulclanker-living-context'], /A new shared procedure/);
  assert.doesNotMatch(next.messages[0].sections['statefulclanker-living-context'], /Living Clanker foundation/);
});
test('verified records without query relevance are not blindly injected', () => {
  const root = repo();
  mkdirSync(join(root, '.clanker', 'knowledge'), { recursive: true });
  writeFileSync(join(root, '.clanker', 'knowledge', 'irrelevant.md'),
    '---\nstatus: verified\n---\n# Unrelated\nA completely different topic.\n');
  const selected = selectKnowledge(root, 'git conflict', ['workspace/checkouts.ts']);
  assert.ok(!selected.sources.some(x => x.path.endsWith('irrelevant.md')));
});
