import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, unlinkSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ensureFoundation, knowledgeGraph, listKnowledge, selectKnowledge } from '../../context/knowledge.ts';
import { projectHistory, registerLivingContext } from '../../context/runtime.ts';
import { updateKnowledge } from '../../context/tools.ts';
import { claimPaths, listCheckouts } from '../../workspace/checkouts.ts';
import { createTask } from '../../project/tasks.ts';
import { recordIntent, setIntentStatus } from '../../project/intent.ts';

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

test('Git CRLF checkout preserves metadata and excludes archived knowledge', () => {
  const root = repo();
  mkdirSync(join(root, '.clanker', 'knowledge'), { recursive: true });
  const path = '.clanker/knowledge/windows.md';
  const raw = '---\nid: windows-id\nstatus: archived\ntags: [windows]\npaths: [workspace/]\nlinks: [other]\n---\n# Windows\nObsolete checkout guidance.\n';
  writeFileSync(join(root, path), raw);
  const git = (...args: string[]) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' });
  git('config', 'core.autocrlf', 'true');
  git('add', '--', path); git('commit', '-qm', 'knowledge');
  unlinkSync(join(root, path));
  git('checkout-index', '--force', '--', path);
  const bytes = readFileSync(join(root, path), 'utf8');
  assert.ok(bytes.includes('\r\n'));
  const doc = listKnowledge(root).find(d => d.path === path)!;
  assert.equal(doc.id, 'windows-id'); assert.equal(doc.status, 'archived');
  assert.deepEqual(doc.paths, ['workspace/']); assert.deepEqual(doc.tags, ['windows']);
  assert.deepEqual(doc.links, ['other']);
  assert.equal(doc.hash, createHash('sha256').update(bytes).digest('hex'));
  assert.ok(!selectKnowledge(root, 'checkout', ['workspace/checkouts.ts']).sources.some(s => s.path === path));
});

test('projection retains old human steering and reinjects governing intent and complete task requirements', async () => {
  const root = repo(), handlers: Record<string, (e: any) => any> = {};
  const intent = recordIntent(root, { statement: 'Never touch deployment files', scope: 'project', source: 'human' });
  const task = createTask(root, { title: 'Parser', objective: 'Parse input', constraints: ['No network access'],
    scope: { files: ['parser.ts'], subsystem: 'parser', worktree: '' },
    expected_outputs: ['parser implementation'], verification_expectations: ['reject malformed input'] });
  const previous = process.env.SC_TASK_ID;
  process.env.SC_TASK_ID = task.id;
  try {
    registerLivingContext({ on(name: string, fn: (e: any) => any) { handlers[name] = fn; } } as any, () => root, () => 'W01');
    const messages: any[] = [{ role: 'user', content: 'assignment' }, { role: 'user', content: 'Old crucial steering' }];
    for (let i = 0; i < 10; i++) messages.push({ role: 'user', content: `steering ${i}` },
      { role: 'assistant', content: 'x'.repeat(3000) }, { role: 'toolResult', content: 'y'.repeat(3000) });
    const projected = await handlers.context!({ messages });
    assert.ok(projected.messages.some((m: any) => m.content === 'Old crucial steering'));
    assert.ok(projected.messages.length < messages.length);
    const compiled = await handlers.context_with_system!({ messages: [{ role: 'system', sections: {} }, ...projected.messages] });
    const section = compiled.messages[0].sections['statefulclanker-living-context'];
    for (const requirement of ['Never touch deployment files', 'No network access', 'parser.ts',
      'parser implementation', 'reject malformed input']) assert.ok(section.includes(requirement), requirement);
    setIntentStatus(root, intent.id, 'withdrawn');
    const next = await handlers.context_with_system!({ messages: [{ role: 'system', sections: {} }] });
    assert.ok(!next.messages[0].sections['statefulclanker-living-context'].includes('Never touch deployment files'));
  } finally { if (previous === undefined) delete process.env.SC_TASK_ID; else process.env.SC_TASK_ID = previous; }
});

test('identical memory writes do not claim paths or create empty commits, including CRLF equivalents', () => {
  const root = repo(), path = '.clanker/knowledge/same.md', content = '# Same\nContent\n';
  const made = updateKnowledge(root, 'W01', path, content, null);
  const git = (...args: string[]) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' }).trim();
  const head = git('rev-parse', 'HEAD');
  const result = updateKnowledge(root, 'W02', path, content.replace(/\n/g, '\r\n'), made.hash!);
  assert.equal(result.unchanged, true); assert.equal(result.hash, made.hash);
  assert.equal(git('rev-parse', 'HEAD'), head); assert.deepEqual(listCheckouts(root).claims, []);
});

test('failed memory commit preserves unpublished content with explicit ownership recovery', () => {
  const root = repo(), path = '.clanker/knowledge/recovery.md';
  // A Git identity error is portable and fails publication after the file has been replaced.
  execFileSync('git', ['-C', root, 'config', 'user.name', '']);
  assert.throws(() => updateKnowledge(root, 'W01', path, '# Unpublished\nKeep this evidence\n', null), /claim retained.*checkout_publish/s);
  assert.match(readFileSync(join(root, path), 'utf8'), /Keep this evidence/);
  assert.equal(listCheckouts(root).claims[0]?.owner, 'W01');
  assert.ok(!readdirSync(join(root, '.clanker', 'knowledge')).some(name => name.endsWith('.tmp')));
});
