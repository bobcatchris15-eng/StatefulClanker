import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const git = (root: string, ...a: string[]) =>
  execFileSync('git', ['-C', root, ...a], { encoding: 'utf8', windowsHide: true }).trim();

export function createWorktree(root: string, workerId: string, slug: string): { path: string; branch: string; base_commit: string } {
  root = resolve(root);
  const path = join(root, '.statefulclanker', 'worktrees', workerId);
  const branch = `clanker/${workerId.toLowerCase().replace(/^w(\d)/, 'w-$1')}/${slug}`;
  const base_commit = git(root, 'rev-parse', 'HEAD');
  const gitDir = resolve(root, git(root, 'rev-parse', '--git-dir'));
  const exFile = join(gitDir, 'info', 'exclude');
  mkdirSync(join(gitDir, 'info'), { recursive: true });
  const cur = existsSync(exFile) ? readFileSync(exFile, 'utf8') : '';
  const entry = '.statefulclanker/worktrees';
  if (!cur.split(/\r?\n/).includes(entry)) appendFileSync(exFile, (cur && !cur.endsWith('\n') ? '\n' : '') + entry + '\n');
  mkdirSync(join(root, '.statefulclanker', 'worktrees'), { recursive: true });
  git(root, 'worktree', 'add', '-b', branch, path, base_commit);
  return { path, branch, base_commit };
}
