import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ensureFoundation, knowledgeGraph, listKnowledge, selectKnowledge } from '../../context/knowledge.ts';
import { projectHistory } from '../../context/runtime.ts';
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
