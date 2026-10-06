import type { CandidateModel } from "./types.ts";

/** Structural subset of pi's ModelRegistry / ExtensionContext (no pi import at runtime). */
export interface RegistryLike {
  getAvailable(): any[];
  find?(provider: string, id: string): any | undefined;
  hasConfiguredAuth?(model: any): boolean;
  getRegisteredProviderIds?(): readonly string[];
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
 * Candidate pool: registry.getAvailable() (auth configured) intersected with scopedModels (when non-empty).
 * Providers returned by getRegisteredProviderIds() are treated as parent-only extension providers (a worker
 * process would not have them) and excluded unless listed in workerExtensions. NOTE: getRegisteredProviderIds()
 * semantics are inferred from its name/typings; it may also list non-extension registrations, which is why
 * the allow-list exists.
 */
export function buildPool(ctx: PoolCtx, opts: { workerExtensions?: string[] } = {}): PoolResult {
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
  const reg = new Set(ctx.modelRegistry.getRegisteredProviderIds?.() ?? []);
  const allow = new Set(opts.workerExtensions ?? []);
  const candidates: CandidateModel[] = [];
  for (const m of models) {
    const c = toCandidate(m);
    if (reg.has(c.provider) && !allow.has(c.provider)) {
      excluded.push({ key: c.key, why: `provider ${c.provider} is parent-only extension (not in workerExtensions)` });
      continue;
    }
    candidates.push(c);
  }
  return { candidates, excluded };
}
