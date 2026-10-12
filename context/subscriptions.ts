/** Durable deterministic relevance routing; no additional model inference. */
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { ensureLayout } from '../project/paths.ts';
import { appendEvent } from '../protocol/events.ts';
import { readJson, writeJsonAtomic } from '../protocol/persistence.ts';

export interface Interest { paths: string[]; topics: string[] }
export interface RelevantChange { id: string; path: string; from: string; commit: string; reason: string; created_at: string; delivered_at?: string }
interface Db { watchers: Record<string, Interest>; inbox: Record<string, RelevantChange[]> }
const location = (root: string) => join(ensureLayout(root), 'context', 'subscriptions.json');
const read = (root: string): Db => {
  const x = readJson<Partial<Db>>(location(root), {});
  return { watchers: x.watchers ?? {}, inbox: x.inbox ?? {} };
};
const spin = new Int32Array(new SharedArrayBuffer(4));
function locked<T>(root: string, fn: (db: Db) => T): T {
  const lock = join(ensureLayout(root), 'context', '.subscriptions-lock');
  let found = false;
  for (let i = 0; i < 100; i++) {
    try { mkdirSync(lock); found = true; break; }
    catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
      Atomics.wait(spin, 0, 0, 20);
    }
  }
  if (!found) throw Error('context inbox lock busy');
  try {
    const db = read(root), result = fn(db);
    writeJsonAtomic(location(root), db);
    return result;
  } finally { rmSync(lock, { recursive: true, force: true }); }
}
const norm = (x: string) => x.toLowerCase().replace(/\\/g, '/').trim();
export const tokens = (s: string) => [...new Set(s.toLowerCase().match(/[a-z][a-z0-9_-]{3,}/g) ?? [])]
  .filter(t => !['from','into','with','this','that','task','worker','implementation','review'].includes(t));
function pathOf(p: string): string {
  const x = norm(p);
  if (!x || x.startsWith('/') || /^[a-z]:/.test(x) || x.split('/').some(y => y === '.' || y === '..') ||
    x.startsWith('.git/') || x.startsWith('.statefulclanker/')) throw Error('invalid watched path');
  return x;
}
export function watch(root: string, actor: string, change: Partial<Interest>, replace = false): Interest {
  const paths = (change.paths ?? []).map(pathOf), topics = (change.topics ?? []).flatMap(tokens);
  return locked(root, db => {
    const old = replace ? {paths:[],topics:[]} : (db.watchers[actor] ?? {paths:[],topics:[]});
    const next = { paths: [...new Set([...old.paths, ...paths])],
      topics: [...new Set([...old.topics, ...topics])] };
    if (next.paths.length > 50 || next.topics.length > 50) throw Error('subscription limit (50)');
    db.watchers[actor] = next; return next;
  });
}
export const getWatch = (root: string, actor: string): Interest =>
  read(root).watchers[actor] ?? {paths:[],topics:[]};
export function stopWatching(root: string, actor: string): void {
  locked(root, db => { delete db.watchers[actor]; delete db.inbox[actor]; });
}
export function initializeTaskInterest(root: string, actor: string, p: {paths?: string[]; task?: string; hints?: string[]}): void {
  watch(root, actor, {paths:p.paths ?? [], topics:tokens([p.task ?? '',...(p.hints ?? [])].join(' ')).slice(0,50)});
}
const covers = (scope: string, path: string) => {
  const a = norm(scope).replace(/\/$/, ''), b = norm(path);
  return a === b || b.startsWith(a + '/');
};
function pathTopics(root: string, path: string): Set<string> {
  const set = new Set(tokens(path));
  if (path.startsWith('.clanker/') && path.endsWith('.md') && existsSync(join(root,path))) {
    const raw = readFileSync(join(root,path),'utf8').slice(0,12000);
    const front = raw.startsWith('---') ? raw.slice(0, Math.max(0,raw.indexOf('\n---',3))) : '';
    for (const t of tokens(front + ' ' + (/^#\s+(.+)$/m.exec(raw)?.[1] ?? ''))) set.add(t);
  }
  return set;
}
export function recordRelevantChange(root: string, from: string, paths: string[], commit: string): number {
  const normalized = paths.map(pathOf), tags = normalized.map(p => pathTopics(root,p));
  const count = locked(root, db => {
    let sent=0;
    for (const [actor, interest] of Object.entries(db.watchers)) {
      if (actor === from) continue;
      for (let i=0; i<normalized.length; i++) {
        const path=normalized[i]!;
        const byPath=interest.paths.some(p=>covers(p,path)||covers(path,p));
        const byTopic=interest.topics.some(t=>tags[i]!.has(t));
        if (!byPath && !byTopic) continue;
        const inbox = db.inbox[actor] ??= [];
        if (inbox.some(v=>v.path===path && v.commit===commit)) continue;
        inbox.push({id:randomUUID(),path,from,commit,reason:byPath?'path':'topic',
          created_at:new Date().toISOString()});
        if (inbox.length>500 && inbox.filter(v=>!v.delivered_at).length<400)
          db.inbox[actor]=inbox.slice(-500);
        sent++;
      }
    }
    return sent;
  });
  if (count) appendEvent(root,'context.relevance_enqueued',{from,paths:normalized,commit,recipients:count});
  return count;
}
export const pendingRelevant=(root:string,actor:string,max=8):RelevantChange[] =>
  (read(root).inbox[actor] ?? []).filter(e=>!e.delivered_at).slice(0,max);
export function markRelevantDelivered(root:string,actor:string,ids:string[]):void {
  if (!ids.length) return;
  locked(root,db=>{for(const ev of db.inbox[actor] ?? []) if(ids.includes(ev.id))
    ev.delivered_at ??= new Date().toISOString();});
  appendEvent(root,'context.relevance_delivered',{actor,ids});
}
