/** Evidence-backed knowledge verification and durable peer challenges. */
import { randomUUID } from 'node:crypto';
import { mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { appendEvent } from '../protocol/events.ts';
import { ensureLayout } from '../project/paths.ts';
import { readJson, writeJsonAtomic } from '../protocol/persistence.ts';

export interface Attestation {
  hash: string; by: string; evidence: string[]; at: string;
}
export interface Challenge {
  id: string; path: string; hash: string; by: string; reason: string;
  evidence: string[]; status: 'open' | 'resolved'; resolution?: string;
  resolution_evidence?: string[]; resolved_by?: string; at: string;
}
interface EvidenceLedger {
  attestations: Record<string, Attestation>;
  challenges: Challenge[];
}
const EMPTY = (): EvidenceLedger => ({ attestations: {}, challenges: [] });
const file = (root: string) => join(ensureLayout(root), 'knowledge', 'evidence.json');
const load = (root: string): EvidenceLedger => {
  const d = readJson<Partial<EvidenceLedger>>(file(root), EMPTY());
  return { attestations: d.attestations ?? {}, challenges: d.challenges ?? [] };
};
const pause = new Int32Array(new SharedArrayBuffer(4));
function mutate<T>(root: string, fn: (db: EvidenceLedger) => T): T {
  const dir = join(ensureLayout(root), 'knowledge');
  mkdirSync(dir, { recursive: true });
  const lock = join(dir, '.lock');
  let acquired = false;
  for (let i = 0; i < 100; i++) {
    try { mkdirSync(lock); acquired = true; break; }
    catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
      Atomics.wait(pause, 0, 0, 20);
    }
  }
  if (!acquired) throw Error('knowledge evidence ledger is busy');
  try {
    const db = load(root), result = fn(db);
    writeJsonAtomic(file(root), db);
    return result;
  } finally { rmSync(lock, { recursive: true, force: true }); }
}
function ensureEvidence(evidence: string[]): string[] {
  const entries = evidence.map(x => x.trim()).filter(Boolean);
  if (!entries.length || entries.length > 20 || entries.some(x => x.length > 1000))
    throw Error('provide 1–20 nonempty, bounded evidence references');
  return entries;
}
export function assessEvidence(root: string, path: string, hash: string,
  declared: string): { status: string; evidence: string[]; open_challenges: number } {
  const db = load(root);
  const open = db.challenges.filter(c => c.path === path && c.hash === hash && c.status === 'open');
  const att = db.attestations[path];
  const verified = att?.hash === hash;
  const obsolete = ['archived', 'superseded', 'rejected'].includes(declared);
  return { status: obsolete ? declared : open.length ? 'contested' : verified ? 'verified'
    : ['observed', 'proposed'].includes(declared) ? declared : 'provisional',
    evidence: verified ? att!.evidence : [], open_challenges: open.length };
}
export function listChallenges(root: string, path?: string): Challenge[] {
  return load(root).challenges.filter(c => !path || c.path === path);
}
export function challengeKnowledge(root: string, actor: string, path: string,
  currentHash: string, reason: string, evidence: string[]): Challenge {
  if (!reason.trim() || reason.length > 3000) throw Error('bounded reason required');
  return mutate(root, db => {
    const challenge: Challenge = { id: randomUUID(), path, hash: currentHash, by: actor,
      reason: reason.trim(), evidence: ensureEvidence(evidence), status: 'open',
      at: new Date().toISOString() };
    db.challenges.push(challenge);
    appendEvent(root, 'knowledge.challenged', { id: challenge.id, path, hash: currentHash, by: actor });
    return challenge;
  });
}
export function verifyKnowledge(root: string, actor: string, path: string,
  currentHash: string, evidence: string[]): Attestation {
  return mutate(root, db => {
    if (db.challenges.some(c => c.path === path && c.hash === currentHash && c.status === 'open'))
      throw Error('resolve outstanding challenges before verification');
    const att: Attestation = { hash: currentHash, by: actor, evidence: ensureEvidence(evidence),
      at: new Date().toISOString() };
    db.attestations[path] = att;
    appendEvent(root, 'knowledge.verified', { path, hash: currentHash, by: actor });
    return att;
  });
}
export function resolveChallenge(root: string, actor: string, id: string,
  resolution: string, evidence: string[]): Challenge {
  if (!resolution.trim() || resolution.length > 3000) throw Error('bounded resolution required');
  return mutate(root, db => {
    const c = db.challenges.find(x => x.id === id);
    if (!c || c.status !== 'open') throw Error('open challenge not found');
    c.status = 'resolved'; c.resolution = resolution.trim();
    c.resolution_evidence = ensureEvidence(evidence);
    c.resolved_by = actor;
    appendEvent(root, 'knowledge.challenge_resolved', { id, path: c.path, by: actor });
    return c;
  });
}
