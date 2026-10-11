/** All Clankers can read, graph, and mutate the shared substrate. Mutations use checkout authority. */
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { claimPaths, hashFile, listCheckouts, proposeWrite, publish, releasePaths, scopePath } from '../workspace/checkouts.ts';
import { FOUNDATION, knowledgeGraph, listKnowledge, scoreKnowledge } from './knowledge.ts';
import { replaceFileAtomic } from '../protocol/persistence.ts';

const out = (x: unknown) => ({ content: [{ type: 'text' as const, text: typeof x === 'string' ? x : JSON.stringify(x, null, 2) }], details: {} });
function check(root: string, path: string): string {
  const parsed = scopePath(root, path);
  if (parsed.recursive || (parsed.path !== FOUNDATION && !parsed.path.startsWith('.clanker/knowledge/')) ||
      !parsed.path.endsWith('.md')) throw Error('memory path must be .clanker/foundation.md or .clanker/knowledge/*.md');
  return parsed.path;
}
export function updateKnowledge(root: string, actor: string, name: string, content: string, expectedHash: string | null):
  { commit?: string; proposal_id?: string; hash?: string; unchanged?: boolean } {
  const path = check(root, name);
  if (Buffer.byteLength(content, 'utf8') > 64000) throw Error('knowledge entry too large (64 KB max)');
  if (!content.trim()) throw Error('empty knowledge entry');
  const current = hashFile(root, path);
  if (current !== expectedHash) throw Error('stale knowledge revision: read the latest memory and retry');
  const dest = join(root, path);
  // Git normalizes CRLF: equivalent content needs neither a claim nor an empty commit.
  if (current !== null && readFileSync(dest, 'utf8').replace(/\r\n/g, '\n') === content.replace(/\r\n/g, '\n'))
    return { hash: current, unchanged: true };
  const claims = listCheckouts(root).claims;
  const holder = claims.find(c => c.path.toLowerCase() === path.toLowerCase() ||
    c.recursive && path.toLowerCase().startsWith(c.path.toLowerCase() + '/'));
  if (holder && holder.owner !== actor) return { proposal_id: proposeWrite(root, actor, path, expectedHash, content) };
  let claimed = false;
  if (!holder) { claimPaths(root, actor, [path]); claimed = true; }
  const tmp = dest + '.' + randomUUID() + '.tmp';
  try {
    if (hashFile(root, path) !== expectedHash) throw Error('knowledge changed before claim; retry');
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(tmp, content, 'utf8');
    replaceFileAtomic(tmp, dest);
    const commit = publish(root, actor, [path], 'knowledge: update ' + path);
    if (claimed) releasePaths(root, actor, [path]);
    return { commit, hash: hashFile(root, path) ?? undefined };
  } catch (error) {
    let recovery = '';
    if (claimed) {
      try { releasePaths(root, actor, [path]); }
      catch { recovery = ` Checkout claim retained for ${actor} on ${path} to protect unpublished changes or pending collaboration. Inspect the file, then use checkout_publish or operator handoff to recover.`; }
    } else if (holder?.owner === actor) {
      recovery = ` Existing checkout ownership for ${actor} on ${path} is preserved. Inspect the file, then use checkout_publish or operator handoff to recover.`;
    }
    throw Error(`Knowledge update failed for ${path}: ${(error as Error).message}.${recovery}`);
  } finally { if (existsSync(tmp)) rmSync(tmp, { force: true }); }
}
export function registerMemoryTools(pi: ExtensionAPI, root: () => string, actor: () => string): void {
  const tool = (name: string, desc: string, parameters: any, fn: (args: any) => unknown) =>
    pi.registerTool({ name, label: name, description: desc, parameters,
      async execute(_id: string, args: any) {
        try { return out(fn(args)); } catch (e) { return out('error: ' + (e as Error).message); }
      } });
  tool('memory_search', 'Search common Markdown knowledge by terms and optional source paths.', Type.Object({
    query: Type.String(), paths: Type.Optional(Type.Array(Type.String())),
  }), p => listKnowledge(root()).map(d => ({ d, score: scoreKnowledge(d, p.query, p.paths ?? []) }))
    .filter(x => x.score > 0).sort((a,b) => b.score-a.score).slice(0, 12)
    .map(x => ({ id: x.d.id, path: x.d.path, hash: x.d.hash, score: x.score, status: x.d.status,
      snippet: x.d.body.slice(0, 450) })));
  tool('memory_read', 'Read one shared knowledge file and its current compare-and-swap revision hash.', Type.Object({
    path: Type.String(),
  }), p => { const path = check(root(), p.path), file = join(root(), path);
    return { path, hash: hashFile(root(), path), content: existsSync(file) ? readFileSync(file, 'utf8') : null }; });
  tool('memory_graph', 'Inspect Markdown/wiki-link graph (nodes and directed links).', Type.Object({}),
    () => knowledgeGraph(listKnowledge(root())));
  tool('memory_write', 'Revise or add Git-tracked knowledge at an exact base hash; direct commit if free/owned, otherwise propose to checkout owner. Does not bypass human intent.', Type.Object({
    path: Type.String(), content: Type.String(), base_hash: Type.Union([Type.String(), Type.Null()]),
  }), p => updateKnowledge(root(), actor(), p.path, p.content, p.base_hash));
}
