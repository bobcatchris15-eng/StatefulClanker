/**
 * Cooperative shared-checkout ownership. Every worker runs in the SAME repository cwd.
 * A checkout is the right to integrate/commit a path, not a read lock or a virtual filesystem.
 * CLI filesystem writes cannot be prevented here: this is a voluntary broker protocol.
 */
import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { isAbsolute, join, resolve } from 'node:path';
import { appendEvent } from '../protocol/events.ts';
import { readJson, writeJsonAtomic } from '../protocol/persistence.ts';
import { ensureLayout } from '../project/paths.ts';

export interface Claim { path: string; recursive: boolean; owner: string; acquired_at: string }
export interface Proposal { id: string; path: string; from: string; to: string; base_hash: string | null; content: string; created_at: string; status: 'pending' | 'accepted' | 'rejected' }

export type NoticeKind = 'proposal' | 'proposal_result' | 'solicit' | 'solicitation_result';
export interface CollaborationNotice {
  id: string; kind: NoticeKind; from: string; to: string; ref_id: string; path: string;
  created_at: string; delivered_at?: string;
}
export interface Solicitation {
  id: string; owner: string; paths: string[]; objective: string;
  target?: string; spawn_new: boolean; ability_profile: string;
  status: 'pending' | 'routing' | 'dispatching' | 'assigned' | 'failed' | 'closed';
  assigned_worker?: string; error?: string; result?: { status: string; summary: string }; created_at: string;
}
interface Ledger { claims: Claim[]; proposals: Proposal[]; notices: CollaborationNotice[]; solicitations: Solicitation[] }
const EMPTY = (): Ledger => ({ claims: [], proposals: [], notices: [], solicitations: [] });
const hash = (s: string) => createHash('sha256').update(s).digest('hex');
const file = (root: string) => join(ensureLayout(root), 'checkouts', 'ledger.json');
const load = (root: string): Ledger => {
  const raw = readJson<Partial<Ledger>>(file(root), EMPTY());
  return { claims: raw.claims ?? [], proposals: raw.proposals ?? [],
    notices: raw.notices ?? [], solicitations: raw.solicitations ?? [] };
};
const notify = (db: Ledger, kind: NoticeKind, from: string, to: string, ref_id: string, path: string) => {
  db.notices.push({ id: randomUUID(), kind, from, to, ref_id, path, created_at: new Date().toISOString() });
};
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
    notify(db, 'proposal', actor, c.owner, prop.id, p.path);
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
    notify(db, 'proposal_result', actor, p.from, p.id, p.path);
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
      if (db.proposals.some((proposal) => proposal.to === actor && proposal.status === 'pending' && covers(p, proposal.path)))
        throw Error('pending proposals for ' + p.path + ': resolve or transfer before release');
      if (db.solicitations.some((request) => request.owner === actor &&
        !['closed', 'failed'].includes(request.status) &&
        request.paths.some((path) => covers(p, scopePath(root, path).path))))
        throw Error('outstanding collaboration solicitation for ' + p.path + ': close it before releasing');
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
    for (const n of db.notices) if (!n.delivered_at && n.to === prev && n.kind === 'proposal' &&
      db.proposals.some((q) => q.id === n.ref_id && q.status === 'pending' && covers(c, q.path))) n.to = newOwner;
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

/** The broker is the durable inbox. Undelivered notices are retried after operator restart. */
export function pendingNotices(root: string): CollaborationNotice[] {
  return load(root).notices.filter((n) => !n.delivered_at);
}
export function markNoticeDelivered(root: string, id: string): void {
  locked(root, () => {
    const db = load(root), n = db.notices.find((v) => v.id === id);
    if (!n) throw Error('notice not found');
    if (!n.delivered_at) {
      n.delivered_at = new Date().toISOString();
      writeJsonAtomic(file(root), db);
      appendEvent(root, 'collaboration.delivered', { id, kind: n.kind, to: n.to });
    }
  });
}
export function readSolicitation(root: string, id: string): Solicitation {
  const q = load(root).solicitations.find((v) => v.id === id);
  if (!q) throw Error('solicitation not found');
  return q;
}
export function listSolicitations(root: string): Solicitation[] { return load(root).solicitations; }

/** Only a checkout owner can solicit a modification to its own path(s). */
export function solicitProposals(root: string, actor: string, paths: string[], objective: string,
  options: { target?: string; spawn_new?: boolean; ability_profile?: string } = {}): Solicitation {
  if (!paths.length || !objective.trim()) throw Error('owned paths and objective required');
  if (objective.length > 5000 || paths.length > 20) throw Error('solicitation exceeds size limit');
  if (options.target && options.spawn_new) throw Error('choose an existing target OR spawn_new');
  if (options.target === actor) throw Error('cannot solicit yourself');
  return locked(root, () => {
    const db = load(root), scopes = paths.map((p) => scopePath(root, p));
    for (const p of scopes) if (!owned(db, actor, p.path)) throw Error('only checkout owner can solicit ' + p.path);
    if (db.solicitations.filter((q) => q.owner === actor &&
      ['pending', 'routing', 'dispatching'].includes(q.status)).length >= 3)
      throw Error('too many outstanding solicitation requests for this owner');
    const request: Solicitation = {
      id: randomUUID(), owner: actor, paths, objective, target: options.target,
      spawn_new: !!options.spawn_new, ability_profile: options.ability_profile ?? 'implementation',
      status: 'pending', created_at: new Date().toISOString(),
    };
    db.solicitations.push(request);
    notify(db, 'solicit', actor, request.target ?? 'operator', request.id, scopes[0]!.path);
    writeJsonAtomic(file(root), db);
    appendEvent(root, 'collaboration.solicited', { id: request.id, owner: actor, target: request.target ?? 'operator', spawn_new: request.spawn_new, paths });
    return request;
  });
}
/** Operator chooses an existing worker or authorizes one new specialist. */
export function routeSolicitation(root: string, id: string, target?: string, spawn_new = false): Solicitation {
  if ((!target && !spawn_new) || (target && spawn_new)) throw Error('choose worker target or spawn_new');
  return locked(root, () => {
    const db = load(root), q = db.solicitations.find((v) => v.id === id);
    if (!q || !['routing', 'failed'].includes(q.status)) throw Error('request is not awaiting routing');
    if (target === q.owner) throw Error('cannot solicit yourself');
    q.target = target;
    q.spawn_new = spawn_new;
    q.status = 'pending'; q.error = undefined;
    notify(db, 'solicit', q.owner, target ?? 'operator', q.id, q.paths[0]!);
    writeJsonAtomic(file(root), db);
    return q;
  });
}
/** Reserve a spawn before starting the subprocess, preventing duplicate spawns on restart. */
export function beginSolicitationSpawn(root: string, id: string): boolean {
  return locked(root, () => {
    const db = load(root), q = db.solicitations.find((v) => v.id === id);
    if (!q || q.status !== 'pending' || !q.spawn_new) return false;
    q.status = 'dispatching';
    writeJsonAtomic(file(root), db);
    return true;
  });
}
export function resolveSolicitation(root: string, id: string, status: 'routing' | 'assigned' | 'failed',
  workerId?: string, error?: string): void {
  locked(root, () => {
    const db = load(root), q = db.solicitations.find((v) => v.id === id);
    if (!q) throw Error('solicitation not found');
    q.status = status;
    if (workerId) q.assigned_worker = workerId;
    if (error) q.error = error;
    writeJsonAtomic(file(root), db);
    appendEvent(root, 'collaboration.solicitation_status', { id, status, worker_id: workerId ?? null, error: error ?? null });
  });
}
/** Owner declines a proposed write without touching the shared checkout. */
export function rejectProposal(root: string, actor: string, id: string, reason: string): void {
  locked(root, () => {
    const db = load(root), p = db.proposals.find((v) => v.id === id);
    if (!p || p.status !== 'pending') throw Error('no pending proposal');
    if (p.to !== actor || !owned(db, actor, p.path)) throw Error('only current checkout owner can reject');
    p.status = 'rejected';
    notify(db, 'proposal_result', actor, p.from, p.id, p.path);
    writeJsonAtomic(file(root), db);
    appendEvent(root, 'checkout.rejected', { id, path: p.path, owner: actor, reason: reason.slice(0, 500) });
  });
}

/** Owner closes a request once proposals have been handled, or deliberately cancels the request. */
export function closeSolicitation(root: string, actor: string, id: string): void {
  locked(root, () => {
    const db = load(root), q = db.solicitations.find((r) => r.id === id);
    if (!q || (q.owner !== actor && actor !== 'operator')) throw Error('only the requester/operator may close a solicitation');
    if (q.status === 'dispatching') throw Error('cannot close while helper spawn is dispatching');
    q.status = 'closed';
    writeJsonAtomic(file(root), db);
    appendEvent(root, 'collaboration.solicitation_closed', { id, owner: q.owner, by: actor });
  });
}

/** Give the requester a structured finish receipt; status stays assigned until owner closes it. */
export function recordSolicitationWorkerResult(root: string, workerId: string, status: string, summary: string): string[] {
  return locked(root, () => {
    const db = load(root), completed: string[] = [];
    for (const q of db.solicitations) {
      if (q.assigned_worker !== workerId || q.status !== 'assigned' || q.result) continue;
      q.result = { status: status.slice(0, 100), summary: summary.slice(0, 2000) };
      notify(db, 'solicitation_result', workerId, q.owner, q.id, q.paths[0]!);
      completed.push(q.id);
    }
    if (completed.length) {
      writeJsonAtomic(file(root), db);
      appendEvent(root, 'collaboration.helper_finished', { worker_id: workerId, requests: completed });
    }
    return completed;
  });
}
