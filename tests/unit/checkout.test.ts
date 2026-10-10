import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { acceptProposal, claimPaths, hashFile, listCheckouts, proposeWrite, publish, readProposal, releasePaths, scopePath, transferPath } from '../../workspace/checkouts.ts';

function repo(): string {
  const root = mkdtempSync(join(tmpdir(), 'sc-checkout-'));
  const git = (...a: string[]) => execFileSync('git', ['-C', root, ...a], { encoding: 'utf8' }).trim();
  git('init', '-q'); git('config', 'user.email', 't@t'); git('config', 'user.name', 't');
  writeFileSync(join(root, 'one.txt'), 'one\n');
  writeFileSync(join(root, 'two.txt'), 'two\n');
  git('add', '.'); git('commit', '-qm', 'init');
  return root;
}
const git = (root: string, ...a: string[]) => execFileSync('git', ['-C', root, ...a], { encoding: 'utf8' }).trim();

test('checkout gives one committer but every worker reads the same file', () => {
  const root = repo();
  claimPaths(root, 'W01', ['one.txt']);
  assert.equal(readFileSync(join(root, 'one.txt'), 'utf8'), 'one\n');
  assert.throws(() => claimPaths(root, 'W02', ['one.txt']), /held by W01/);
  claimPaths(root, 'W02', ['two.txt']);
  assert.equal(listCheckouts(root).claims.length, 2);
  assert.equal(hashFile(root, 'one.txt'), '2c8b08da5ce60398e1f19af0e5dccc744df274b826abe585eaba68c5254348069');
});

test('proposal does not edit file; owner accepts only against original hash', () => {
  const root = repo();
  claimPaths(root, 'W01', ['one.txt']);
  const baseline = hashFile(root, 'one.txt');
  const id = proposeWrite(root, 'W02', 'one.txt', baseline, 'updated\n');
  assert.equal(readFileSync(join(root, 'one.txt'), 'utf8'), 'one\n');
  assert.equal(readProposal(root, 'W01', id).content, 'updated\n');
  assert.throws(() => readProposal(root, 'W03', id), /not a proposal participant/);
  assert.throws(() => acceptProposal(root, 'W02', id), /only current checkout owner/);
  acceptProposal(root, 'W01', id);
  assert.equal(readFileSync(join(root, 'one.txt'), 'utf8'), 'updated\n');
  assert.equal(listCheckouts(root).proposals[0]!.status, 'accepted');
});

test('stale proposal fails instead of overwriting later changes', () => {
  const root = repo();
  claimPaths(root, 'W01', ['one.txt']);
  const id = proposeWrite(root, 'W02', 'one.txt', hashFile(root, 'one.txt'), 'proposed\n');
  writeFileSync(join(root, 'one.txt'), 'owner changed\n');
  assert.throws(() => acceptProposal(root, 'W01', id), /changed since proposal/);
});

test('checkout_publish commits only owned paths, preserving unrelated staged changes', () => {
  const root = repo();
  claimPaths(root, 'W01', ['one.txt']);
  claimPaths(root, 'W02', ['two.txt']);
  writeFileSync(join(root, 'one.txt'), 'from W01\n');
  writeFileSync(join(root, 'two.txt'), 'from W02\n');
  git(root, 'add', 'two.txt'); // another worker has staged this, but NOT committed it
  assert.throws(() => publish(root, 'W01', ['two.txt'], 'bad'), /no checkout right-of-way/);
  const commit = publish(root, 'W01', ['one.txt'], 'W01 change');
  assert.equal(git(root, 'rev-parse', 'HEAD'), commit);
  assert.equal(git(root, 'show', '--format=', '--name-only', 'HEAD'), 'one.txt');
  assert.equal(git(root, 'diff', '--cached', '--name-only'), 'two.txt');
  assert.throws(() => releasePaths(root, 'W02', ['two.txt']), /uncommitted changes/);
  releasePaths(root, 'W01', ['one.txt']);
  assert.equal(listCheckouts(root).claims.length, 1);
});

test('owner can publish new files with intent-to-add; handoff transfers responsibility', () => {
  const root = repo();
  claimPaths(root, 'W01', ['new.txt']);
  writeFileSync(join(root, 'new.txt'), 'new\n');
  publish(root, 'W01', ['new.txt'], 'add new');
  assert.equal(git(root, 'show', '--format=', '--name-only', 'HEAD'), 'new.txt');
  transferPath(root, 'new.txt', 'W02');
  assert.equal(listCheckouts(root).claims[0]!.owner, 'W02');
  assert.throws(() => publish(root, 'W01', ['new.txt'], 'no'), /no checkout right-of-way/);
});

test('subtree claims overlap files, and paths cannot escape repository', () => {
  const root = repo();
  claimPaths(root, 'W01', ['src/']);
  assert.throws(() => claimPaths(root, 'W02', ['src/a.ts']), /held by W01/);
  assert.throws(() => claimPaths(root, 'W02', ['src/']), /held by W01/);
  assert.throws(() => scopePath(root, '../outside'), /invalid/);
  assert.throws(() => scopePath(root, '.git/config'), /metadata/);
  assert.throws(() => scopePath(root, '.statefulclanker/ledger.json'), /broker state/);
});
