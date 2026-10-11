/** Git-tracked Markdown substrate; graph and search indexes are rebuilt deterministically. */
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';

export const FOUNDATION = '.clanker/foundation.md';
export const DEFAULT_FOUNDATION = [
  '# Living Clanker foundation',
  '',
  'This is shared, mutable operating knowledge for every Clanker, irrespective of provider or role.',
  'Treat this as revisable project context, below human instructions, the assigned task, and the harness authority contract.',
  'Verify claims against code, tests, and current user intent. Preserve provenance and contradictions.',
  'Use memory_write to add or revise knowledge when useful; use memory_search and memory_graph to discover connections.',
  'Develop this foundation through experience. Do not mistake its current contents for inviolable machinery.',
  '',
].join('\n');

export interface KnowledgeDoc {
  id: string;
  path: string;
  title: string;
  body: string;
  hash: string;
  status: string;
  tags: string[];
  paths: string[];
  links: string[];
}
export interface SelectedKnowledge {
  text: string;
  sources: { path: string; hash: string; score: number }[];
  fingerprint: string;
}
const sha = (s: string) => createHash('sha256').update(s).digest('hex');
const low = (s: string) => s.toLowerCase().replace(/\\/g, '/');
const terms = (s: string) => [...new Set(s.toLowerCase().match(/[a-z][a-z0-9_-]{2,}/g) ?? [])];
function values(s: string | undefined): string[] {
  return (s ?? '').replace(/^\[/, '').replace(/\]$/, '').split(',').map(v => v.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
}
function parse(path: string, raw: string): KnowledgeDoc {
  let body = raw, meta: Record<string,string> = {};
  if (raw.startsWith('---\n')) {
    const end = raw.indexOf('\n---', 4);
    if (end > 0) {
      for (const line of raw.slice(4, end).split('\n')) {
        const match = /^([a-z_]+):\s*(.*)$/.exec(line);
        if (match) meta[match[1]!] = match[2]!;
      }
      body = raw.slice(end + 4).trimStart();
    }
  }
  const title = /^#\s+(.+)$/m.exec(body)?.[1]?.trim() ?? path;
  const inline = [...body.matchAll(/\[\[([^\]]+)\]\]/g)].map(m => m[1]!.split('|')[0]!.trim());
  const linkedMd = [...body.matchAll(/\[[^\]]+\]\(([^)#?]+\.md)(?:#[^)]*)?\)/g)].map(m => m[1]!);
  return { id: meta.id || path.replace(/^\.clanker\/knowledge\//, '').replace(/\.md$/, ''),
    path, title, body, hash: sha(raw), status: meta.status ?? 'provisional',
    tags: values(meta.tags), paths: values(meta.paths), links: [...new Set([...values(meta.links), ...inline, ...linkedMd])] };
}
export function ensureFoundation(root: string): void {
  const base = join(root, '.clanker');
  if (existsSync(base) && lstatSync(base).isSymbolicLink()) throw Error('symlinked .clanker roots are unsupported');
  const file = join(root, FOUNDATION);
  if (existsSync(file)) { if (lstatSync(file).isSymbolicLink()) throw Error('symlinked foundation is unsupported'); return; }
  mkdirSync(join(root, '.clanker'), { recursive: true });
  try { writeFileSync(file, DEFAULT_FOUNDATION, { encoding: 'utf8', flag: 'wx' }); }
  catch (e) { if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e; }
}
export function listKnowledge(root: string): KnowledgeDoc[] {
  ensureFoundation(root);
  const base = join(root, '.clanker');
  const out: KnowledgeDoc[] = [];
  const walk = (dir: string, depth: number): void => {
    if (depth > 6 || out.length >= 400) return;
    for (const name of readdirSync(dir).sort()) {
      if (out.length >= 400 || name.startsWith('.') && name !== 'foundation.md') continue;
      const full = join(dir, name), stat = lstatSync(full);
      if (stat.isSymbolicLink()) continue;
      if (stat.isDirectory()) { walk(full, depth + 1); continue; }
      if (!name.endsWith('.md') || !stat.isFile() || stat.size > 64_000) continue;
      const path = relative(root, full).replace(/\\/g, '/');
      out.push(parse(path, readFileSync(full, 'utf8')));
    }
  };
  walk(base, 0);
  return out;
}
export function knowledgeGraph(docs: KnowledgeDoc[]): { nodes: string[]; edges: [string,string][] } {
  const byName = new Map<string,KnowledgeDoc>();
  for (const d of docs) {
    byName.set(low(d.id), d); byName.set(low(d.path), d);
    byName.set(low(d.path.replace(/\.md$/, '')), d);
    byName.set(low(d.title), d);
  }
  const edges: [string,string][] = [];
  for (const d of docs) for (const l of d.links) {
    const target = byName.get(low(l)) ?? byName.get(low(l.replace(/^\.\//, '')));
    if (target && target.path !== d.path) edges.push([d.path, target.path]);
  }
  return { nodes: docs.map(d => d.path), edges };
}
export function scoreKnowledge(d: KnowledgeDoc, query: string, paths: string[] = []): number {
  if (d.path === FOUNDATION) return 100000;
  if (['superseded', 'rejected', 'archived'].includes(d.status)) return -1000;
  const queryTerms = terms(query);
  const title = low(d.title + ' ' + d.id + ' ' + d.tags.join(' '));
  const body = low(d.body);
  let score = 0;
  for (const t of queryTerms) {
    if (title.includes(t)) score += 6;
    else if (body.includes(t)) score += 1;
  }
  for (const p of paths) {
    const key = low(p);
    for (const rule of d.paths) {
      const r = low(rule).replace(/\/$/, '');
      if (r && (key === r || key.startsWith(r + '/') || (r.endsWith('*') && key.startsWith(r.slice(0, -1))))) score += 18;
    }
    if (key && low(d.path).includes(key)) score += 3;
  }
  return score > 0 && d.status === 'verified' ? score + 2 : score;
}
export function selectKnowledge(root: string, query: string, paths: string[] = [], budget = 9500): SelectedKnowledge {
  const docs = listKnowledge(root);
  const foundation = docs.find(d => d.path === FOUNDATION);
  const graph = knowledgeGraph(docs);
  const ranked = docs.filter(d => d.path !== FOUNDATION).map(d => ({ d, score: scoreKnowledge(d, query, paths) }));
  const initial = new Set(ranked.filter(x => x.score > 0).map(x => x.d.path));
  for (const item of ranked) if (graph.edges.some(([a,b]) => (initial.has(a) && b === item.d.path) || (initial.has(b) && a === item.d.path))) item.score += 3;
  ranked.sort((a,b) => b.score - a.score || a.d.path.localeCompare(b.d.path));
  const sources: SelectedKnowledge['sources'] = [];
  const pieces: string[] = [];
  let remaining = Math.max(1500, budget);
  const add = (d: KnowledgeDoc, score: number, reserve = 0): void => {
    if (remaining < 150 || !d.body.trim()) return;
    const cap = Math.min(d.path === FOUNDATION ? 4000 : 2200, remaining - reserve - 100);
    if (cap < 150) return;
    const excerpt = d.body.length > cap ? d.body.slice(0, cap) + '\n[excerpt truncated; use memory_read]' : d.body;
    const passage = '### ' + d.path + ' (' + d.hash.slice(0,12) + '; ' + d.status + ')\n' + excerpt;
    pieces.push(passage);
    remaining -= passage.length;
    sources.push({ path: d.path, hash: d.hash, score });
  };
  if (foundation) add(foundation, 100000, 1200);
  for (const { d, score } of ranked) {
    if (sources.length >= 9 || score <= 0 || remaining < 350) break;
    add(d, score);
  }
  const text = pieces.length ? '## Current shared knowledge (mutable, lower authority than harness and human intent)\n' +
    pieces.join('\n\n') : '';
  return { text, sources, fingerprint: sha(text) };
}
