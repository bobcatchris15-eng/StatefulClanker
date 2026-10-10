/**
 * Cooperative shared-checkout ownership. Every worker runs in the SAME repository cwd.
 * A checkout is the right to integrate/commit a path, not a read lock or a virtual filesystem.
 * CLI filesystem writes cannot be prevented here: this is a voluntary broker protocol.
 */
import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { isAbsolute, join, resolve } from 'node:path';
import { appendEvent } from '../protocol/events.ts';
import { readJson, writeJsonAtomic } from '../protocol/persistence.ts';
import { ensureLayout } from '../project/paths.ts';

export interface Claim { path: string; recursive: boolean; owner: string; acquired_at: string }
export interface Proposal { id: string; path: string; from: string; to: string; base_hash: string | null; content: string; created_at: string; status: 'pending' | 'accepted' | 'rejected' }
interface Ledger { claims: Claim[]; proposals: Proposal[] }
const EMPTY = (): Ledger => ({ claims: [], proposals: [] });
const hash = (s: string) => createHash('sha256').update(s).digest('hex');
const file = (root: string) => join(ensureLayout(root), 'checkouts', 'ledger.json');
const load = (root: string) => readJson<Ledger>(file(root), EMPTY());
const git = (root: string, ...args: string[]) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', windowsHide: true }).trim();
const pause = new Int32Array(new SharedArrayBuffer(4));

/** Files/directories are pathspecs, never arbitrary git arguments. A trailing slash means subtree. */
export function scopePath(root: string, input: string): { path: string; recursive: boolean } {
  if (!input || isAbsolute(input) || /^[A-Za-z]:/.test(input) || input.startsWith('\\\\')) throw Error('expected repository-relative path');
  const recursive = /[/\\]$/.test(input);
  const parts = input.replace(/\\/g, '/').split('/');
  if (parts.some((x) => x === '.' || x === '..') || parts.filter(Boolean).length === 0) throw Error('invalid checkout path');
  const clean = parts.filter(Boolean);
  if (['.git', '.statefulclanker'].includes(clean[0]!.toLowerCase())) throw Error('Git metadata and broker state cannot be checked out');
  if (clean.some((x) => x.includes('\0') || x.includes(':'))) throw Error('invalid checkout path');
  // Reject symlink traversal, including a symlink at the leaf.
  let here = resolve(root);
  for (const p of clean) {
    here = join(here, p);
    if (existsSync(here) && lstatSync(here).isSymbolicLink()) throw Error('symlink checkout paths are unsupported');
  }
  return { path: clean.join('/'), recursive };
}
const key = (s: string) => s.toLowerCase(); // Windows-friendly ownership
const covers = (c: {path: string; recursive: boolean}, p: string) =>
  key(c.path) === key(p) || (c.recursive && key(p).startsWith(key(c.path) + '/'));
const overlap = (a: {path: string; recursive: boolean}, b: {path: string; recursive: boolean}) =>
  covers(a, b.path) || covers(b, a.path);
const owned = (db: Ledger, actor: string, path: string) =>
  db.claims.some((c) => c.owner === actor && covers(c, path));

function locked<T>(root: string, fn: () => T): T {
  const dir = join(ensureLayout(root), 'checkouts');
  mkdirSync(dir, { recursive: true });
  const lock = join(dir, '.lock');
  let acquired = false;
  for (let n = 0; n < 100; n++) {
    try { mkdirSync(lock); acquired = true; break; }
    catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
      // Never steal a possibly-live lock; human recovery is safer than corruption.
      Atomics.wait(pause, 0, 0, 20);
    }
  }
  if (!acquired) throw Error('checkout broker is busy (or has a stale .lock directory)');
  try { return fn(); } finally { rmSync(lock, { recursive: true, force: true }); }
}

export function listCheckouts(root: string): {claims: Claim[]; proposals: Omit<Proposal, 'content'>[]} {
  const db = load(root);
  return { claims: db.claims, proposals: db.proposals.map(({ content, ...p }) => p) };
}
export function claimPaths(root: string, actor: string, paths: string[]): Claim[] {
  if (!actor || !paths.length) throw Error('actor and paths required');
  return locked(root, () => {
    const db = load(root), requested = paths.map((p) => scopePath(root, p));
    for (const p of requested) {
      const conflict = db.claims.find((c) => c.owner !== actor && overlap(c, p));
      if (conflict) throw Error(`checkout ${p.path} held by ${conflict.owner} (${conflict.path})`);
    }
    const created: Claim[] = [];
    for (const p of requested) {
      if (db.claims.some((c) => c.owner === actor && covers(c, p.path))) continue;
      // Replace narrower self-claims when taking a subtree.
      db.claims = db.claims.filter((c) => c.owner !== actor || !covers(p, c.path));
      const c = { ...p, owner: actor, acquired_at: new Date().toISOString() };
      db.claims.push(c); created.push(c);
    }
    writeJsonAtomic(file(root), db);
    for (const c of created) appendEvent(root, 'checkout.claimed', c);
    return created;
  });
}
export function hashFile(root: string, path: string): string | null {
  const p = scopePath(root, path);
  if (p.recursive) throw Error('expected a file');
  const target = join(root, p.path);
  return existsSync(target) ? hash(readFileSync(target, 'utf8')) : null;
}
export function proposeWrite(root: string, actor: string, path: string, baseHash: string | null, content: string): string {
  if (!actor) throw Error('actor required');
  return locked(root, () => {
    const p = scopePath(root, path);
    if (p.recursive) throw Error('proposals must target one file');
    const db = load(root);
    const c = db.claims.find((c) => covers(c, p.path));
    if (!c) throw Error('no checkout owner: request checkout instead');
    if (c.owner === actor) throw Error('you own this file; edit directly');
    const prop: Proposal = { id: randomUUID(), path: p.path, from: actor, to: c.owner,
      base_hash: baseHash, content, created_at: new Date().toISOString(), status: 'pending' };
    db.proposals.push(prop);
    writeJsonAtomic(file(root), db);
    appendEvent(root, 'checkout.proposed', { id: prop.id, path: p.path, from: actor, to: c.owner });
    return prop.id;
  });
}
export function readProposal(root: string, actor: string, id: string): Proposal {
  const db = load(root);
  const p = db.proposals.find((x) => x.id === id);
  if (!p) throw Error('proposal not found');
  if (p.to !== actor && p.from !== actor && actor !== 'operator') throw Error('not a proposal participant');
  return p;
}
export function acceptProposal(root: string, actor: string, id: string): void {
  locked(root, () => {
    const db = load(root), p = db.proposals.find((x) => x.id === id);
    if (!p || p.status !== 'pending') throw Error('no pending proposal');
    if (p.to !== actor || !owned(db, actor, p.path)) throw Error('only current checkout owner can accept');
    if (hashFile(root, p.path) !== p.base_hash) throw Error('file changed since proposal; ask for a rebased proposal');
    const dest = join(root, p.path);
    mkdirSync(resolve(dest, '..'), { recursive: true });
    const tmp = dest + '.' + randomUUID() + '.tmp';
    try { writeFileSync(tmp, p.content, 'utf8'); renameSync(tmp, dest); }
    finally { if (existsSync(tmp)) rmSync(tmp); }
    p.status = 'accepted';
    writeJsonAtomic(file(root), db);
    appendEvent(root, 'checkout.accepted', { id, path: p.path, owner: actor, from: p.from });
  });
}
export function releasePaths(root: string, actor: string, paths: string[]): void {
  locked(root, () => {
    const db = load(root);
    const targets = paths.length ? paths.map((p) => scopePath(root, p)) : db.claims.filter((c) => c.owner === actor);
    for (const p of targets) {
      if (!db.claims.some((c) => c.owner === actor && c.path === p.path && c.recursive === p.recursive))
        throw Error('you do not own exact checkout ' + p.path);
      const status = git(root, 'status', '--porcelain', '--', p.path);
      if (status) throw Error('uncommitted changes in ' + p.path + ': publish or resolve before release');
    }
    db.claims = db.claims.filter((c) => !(c.owner === actor && targets.some((p) => p.path === c.path && p.recursive === c.recursive)));
    writeJsonAtomic(file(root), db);
    for (const p of targets) appendEvent(root, 'checkout.released', { ...p, owner: actor });
  });
}
/** Only the operator can transfer. Never silently discard working changes. */
export function transferPath(root: string, path: string, newOwner: string): void {
  if (!newOwner) throw Error('new owner required');
  locked(root, () => {
    const db = load(root), p = scopePath(root, path);
    const c = db.claims.find((x) => x.path === p.path && x.recursive === p.recursive);
    if (!c) throw Error('exact checkout not found');
    const prev = c.owner;
    if (db.claims.some((x) => x !== c && x.owner !== newOwner && overlap(x, p))) throw Error('overlapping checkout');
    c.owner = newOwner; c.acquired_at = new Date().toISOString();
    for (const prop of db.proposals) if (prop.to === prev && prop.status === 'pending' && covers(c, prop.path)) prop.to = newOwner;
    writeJsonAtomic(file(root), db);
    appendEvent(root, 'checkout.transferred', { ...p, from: prev, to: newOwner });
  });
}
/**
 * Commit ONLY explicit, currently owned paths in the single checkout. Git's --only
 * uses a temporary index, avoiding unrelated staged content. The broker mutex
 * serializes cooperating commits; external git commands remain out of scope.
 */
export function publish(root: string, actor: string, paths: string[], message: string): string {
  if (!paths.length || !message.trim()) throw Error('paths and message required');
  return locked(root, () => {
    const db = load(root), requested = paths.map((p) => scopePath(root, p));
    for (const p of requested) if (!owned(db, actor, p.path)) throw Error('no checkout right-of-way for ' + p.path);
    // Add intent-to-add for new files so --only can include them without including unrelated staging.
    for (const p of requested) git(root, 'add', '-N', '--', p.path);
    const before = git(root, 'rev-parse', 'HEAD');
    git(root, 'commit', '--only', '-m', message, '--', ...requested.map((p) => p.path));
    const after = git(root, 'rev-parse', 'HEAD');
    if (before === after) throw Error('no commit produced');
    appendEvent(root, 'checkout.published', { owner: actor, paths: requested.map((p) => p.path), commit: after });
    return after;
  });
}
