import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createWorktree } from '../../worktrees/create.ts';

test('createWorktree in temp repo', () => {
  const root = mkdtempSync(join(tmpdir(), 'sc-wt-'));
  const g = (...a: string[]) => execFileSync('git', ['-C', root, ...a], { encoding: 'utf8' }).trim();
  g('init', '-q'); g('config', 'user.email', 't@t'); g('config', 'user.name', 't');
  writeFileSync(join(root, 'f.txt'), 'x'); g('add', '.'); g('commit', '-qm', 'init');
  const wt = createWorktree(root, 'W01', 'feat');
  assert.equal(wt.branch, 'clanker/w01/feat');
  assert.equal(wt.base_commit, g('rev-parse', 'HEAD'));
  assert.ok(existsSync(join(wt.path, 'f.txt')));
  assert.ok(readFileSync(join(root, '.git', 'info', 'exclude'), 'utf8').includes('.statefulclanker/worktrees'));
  createWorktree(root, 'W02', 'b');
  assert.equal(readFileSync(join(root, '.git', 'info', 'exclude'), 'utf8').split('.statefulclanker/worktrees').length, 2);
});
