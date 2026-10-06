import type { CandidateModel } from "./types.ts";

/** Structural subset of pi's ModelRegistry / ExtensionContext (no pi import at runtime). */
export interface RegistryLike {
  getAvailable(): any[];
  find?(provider: string, id: string): any | undefined;
  hasConfiguredAuth?(model: any): boolean;
}
export interface PoolCtx {
  modelRegistry: RegistryLike;
  scopedModels?: readonly any[];
  model?: any;
}
export interface PoolResult { candidates: CandidateModel[]; excluded: { key: string; why: string }[] }

export function toCandidate(m: any): CandidateModel {
  const c = m.cost ?? {};
  return {
    key: `${m.provider}/${m.id}`, provider: String(m.provider), id: String(m.id), name: String(m.name ?? m.id),
    reasoning: !!m.reasoning, input: Array.isArray(m.input) ? m.input.map(String) : ["text"],
    contextWindow: Number(m.contextWindow ?? 0), maxTokens: Number(m.maxTokens ?? 0),
    cost: { input: c.input ?? 0, output: c.output ?? 0, cacheRead: c.cacheRead ?? 0, cacheWrite: c.cacheWrite ?? 0 },
  };
}

/**
 * Candidate pool == Pi's available model library: registry.getAvailable() (auth configured) intersected with
 * scopedModels (when non-empty). Workers load the same library and extension providers as the parent, so
 * nothing else is filtered here (health/lease filtering stays in select).
 */
export function buildPool(ctx: PoolCtx): PoolResult {
  const excluded: { key: string; why: string }[] = [];
  let models: any[] = [...ctx.modelRegistry.getAvailable()];
  const scoped = ctx.scopedModels ?? [];
  if (scoped.length) {
    const keys = new Set(scoped.map((s: any) => { const m = s?.model ?? s; return `${m.provider}/${m.id}`; }));
    models = models.filter((m) => {
      const k = `${m.provider}/${m.id}`;
      if (keys.has(k)) return true;
      excluded.push({ key: k, why: "not in scoped models" });
      return false;
    });
  }
  return { candidates: models.map(toCandidate), excluded };
}
