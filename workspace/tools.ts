import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import { acceptProposal, claimPaths, hashFile, listCheckouts, proposeWrite, publish, readProposal, releasePaths, transferPath } from './checkouts.ts';

const out = (s: unknown) => ({ content: [{ type: 'text' as const, text: typeof s === 'string' ? s : JSON.stringify(s, null, 2) }], details: {} });
const paths = () => Type.Array(Type.String());
/** Shared tool protocol for worker zero and workers. Operator-only transfer is explicit. */
export function registerCheckoutTools(pi: ExtensionAPI, root: () => string, actor: () => string, operator = false): void {
  const tool = (name: string, desc: string, parameters: any, fn: (p: any) => unknown) =>
    pi.registerTool({ name, label: name, description: desc, parameters,
      async execute(_id: string, p: any) {
        try { return out(fn(p)); } catch (e) { return out('error: ' + (e as Error).message); }
      },
    });
  tool('checkout_list', 'List checkout owners and pending proposal metadata for the shared project.', Type.Object({}),
    () => listCheckouts(root()));
  tool('checkout_claim', 'Claim commit responsibility/right-of-way for files or subtrees (trailing /). Does not prevent reads.', Type.Object({ paths: paths() }),
    (p) => claimPaths(root(), actor(), p.paths));
  tool('checkout_hash', 'Get SHA-256 of current UTF-8 file content (null if file absent). Use as proposal base_hash.', Type.Object({ path: Type.String() }),
    (p) => ({ path: p.path, hash: hashFile(root(), p.path) }));
  tool('checkout_propose', 'Propose a complete UTF-8 file replacement to its owner; does NOT modify the shared file.', Type.Object({
    path: Type.String(), base_hash: Type.Union([Type.String(), Type.Null()]), content: Type.String(),
  }), (p) => ({ proposal_id: proposeWrite(root(), actor(), p.path, p.base_hash, p.content) }));
  tool('checkout_proposal_read', 'Read a proposed write (content visible only to author, owner or operator).', Type.Object({ id: Type.String() }),
    (p) => readProposal(root(), actor(), p.id));
  tool('checkout_accept', 'As checkout owner, apply a proposal only when its base hash still matches current file.', Type.Object({ id: Type.String() }),
    (p) => { acceptProposal(root(), actor(), p.id); return 'proposal applied; owner must validate and publish'; });
  tool('checkout_publish', 'Commit ONLY explicitly named owned files/subtrees from the shared checkout (no git add -A).', Type.Object({
    paths: paths(), message: Type.String(),
  }), (p) => ({ commit: publish(root(), actor(), p.paths, p.message) }));
  tool('checkout_release', 'Release owned checkouts after all their changes are committed.', Type.Object({ paths: paths() }),
    (p) => { releasePaths(root(), actor(), p.paths); return 'checkouts released'; });
  if (operator) tool('checkout_transfer', 'Operator-only right-of-way handoff/recovery (does not alter file contents).', Type.Object({
    path: Type.String(), new_owner: Type.String(),
  }), (p) => { transferPath(root(), p.path, p.new_owner); return 'checkout transferred'; });
}
