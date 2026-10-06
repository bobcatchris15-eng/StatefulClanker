import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { AbilityRequest, CandidateModel, Capability, Rating } from "./types.ts";
import { buildPool, toCandidate } from "./pool.ts";
import type { PoolCtx } from "./pool.ts";
import { loadCurated, resolveProfile } from "./profiles.ts";
import type { ResolvedProfile } from "./profiles.ts";
import { select } from "./select.ts";
import type { SelectResult } from "./select.ts";
import { aggregate, readOutcomes, recordOutcome } from "./observations.ts";
import type { OutcomeKind } from "./observations.ts";
import { emptyHealth, isCooling, loadHealth, reduce, saveHealth } from "./health.ts";
import type { ModelHealth } from "./health.ts";
import { claim, leaseCounts, reapDead, release, releaseByWorker } from "./leases.ts";
import type { Lease } from "./leases.ts";
import { machineDir, projectProfilesPath } from "./paths.ts";

export interface Resolution {
  ok: boolean;
  reason: string;
  chosen?: { key: string; provider: string; id: string; thinking: "high" | "medium" | undefined };
  ranked: SelectResult["ranked"];
  excluded: { key: string; why: string }[];
  explicit?: boolean;
  error?: string;
}
export interface ServiceOpts {
  root: string;
  /** Supplies the live Pi context (registry, scopedModels, model). Called per resolve. */
  getContext: () => PoolCtx;
  machineDir?: string;
  workerExtensions?: string[];
  pid?: number;
  isAlive?: (pid: number) => boolean;
  leaseTtlMs?: number;
  now?: () => number;
}

const DEFAULT_TTL = 6 * 3_600_000;
function pidAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
}
function splitKey(model: string): [string, string] {
  const i = model.indexOf("/");
  return i < 0 ? ["", model] : [model.slice(0, i), model.slice(i + 1)];
}

export class CatalogService {
  private o: ServiceOpts;
  constructor(o: ServiceOpts) { this.o = o; }
  get dir(): string { return this.o.machineDir ?? machineDir(); }
  get pid(): number { return this.o.pid ?? process.pid; }
  private now(): number { return this.o.now ? this.o.now() : Date.now(); }
  private ctx(): PoolCtx { return this.o.getContext(); }

  parentModelKey(): string | undefined {
    const m = this.ctx().model;
    return m ? `${m.provider}/${m.id}` : undefined;
  }

  private curated() {
    return loadCurated(join(this.dir, "profiles.json"), projectProfilesPath(this.o.root));
  }
  profileFor(m: CandidateModel): ResolvedProfile {
    return resolveProfile(m, this.curated(), aggregate(m.key, readOutcomes(this.dir)));
  }
  pool() { return buildPool(this.ctx(), { workerExtensions: this.o.workerExtensions }); }

  resolve(request: AbilityRequest, opts: { explicit?: string } = {}): Resolution {
    const now = this.now();
    const health = loadHealth(this.dir);
    const counts = leaseCounts(this.dir, now);
    if (opts.explicit) return this.resolveExplicit(opts.explicit, health, counts, now);
    const { candidates, excluded: poolEx } = this.pool();
    const curated = this.curated();
    const outcomes = readOutcomes(this.dir);
    const profiles: Record<string, ResolvedProfile> = {};
    for (const c of candidates) profiles[c.key] = resolveProfile(c, curated, aggregate(c.key, outcomes));
    const r = select(request, candidates, { profiles, health, leaseCounts: counts, now, parentModelKey: this.parentModelKey() });
    const excluded = [...poolEx, ...r.excluded];
    if (!r.chosen) {
      return { ok: false, reason: r.reason, ranked: r.ranked, excluded,
        error: `no model fits: ${excluded.length ? excluded.map((e) => `${e.key}: ${e.why}`).join("; ") : "no candidates"}` };
    }
    return { ok: true, reason: r.reason, chosen: r.chosen, ranked: r.ranked, excluded };
  }

  private resolveExplicit(spec: string, health: Record<string, ModelHealth>, counts: Record<string, number>, now: number): Resolution {
    const fail = (why: string): Resolution => ({ ok: false, reason: "explicit", ranked: [], excluded: [{ key: spec, why }],
      explicit: true, error: `explicit model ${spec}: ${why}` });
    const [provider, id] = splitKey(spec);
    if (!provider || !id) return fail("expected provider/id");
    const reg = this.ctx().modelRegistry;
    const m = reg.find ? reg.find(provider, id) : reg.getAvailable().find((x: any) => x.provider === provider && x.id === id);
    if (!m) return fail("not found in registry");
    if (reg.hasConfiguredAuth && !reg.hasConfiguredAuth(m)) return fail("no configured auth");
    const c = toCandidate(m);
    if (isCooling(health[c.key], now)) return fail(`cooling until ${new Date(health[c.key]!.cooldown_until).toISOString()}`);
    const cap = this.profileFor(c).lease_capacity;
    if (cap !== null && (counts[c.key] ?? 0) >= cap) return fail(`lease full (${counts[c.key] ?? 0}/${cap})`);
    return { ok: true, reason: "explicit", explicit: true, ranked: [], excluded: [],
      chosen: { key: c.key, provider: c.provider, id: c.id, thinking: c.reasoning ? "medium" : undefined } };
  }

  private rawModel(model: string): any | undefined {
    const [provider, id] = splitKey(model);
    return this.ctx().modelRegistry.getAvailable().find((x: any) => x.provider === provider && x.id === id);
  }

  claimLease(model: string, workerId: string): Lease | null {
    const m = this.rawModel(model);
    const cap = m ? this.profileFor(toCandidate(m)).lease_capacity : null;
    return claim(model, { worker_id: workerId, parent_pid: this.pid }, cap, this.o.leaseTtlMs ?? DEFAULT_TTL, this.dir, this.now());
  }
  releaseLease(leaseId: string): boolean { return release(leaseId, this.dir); }
  releaseWorker(workerId: string): number { return releaseByWorker(workerId, this.dir); }
  /** Reap leases whose parent pid is dead or that expired. */
  recover(): number { return reapDead(this.o.isAlive ?? pidAlive, this.dir, this.now()); }

  reportOutcome(model: string, outcome: OutcomeKind,
    extra: { task_class?: string; latency_ms?: number; worker_id?: string; note?: string } = {}): ModelHealth {
    recordOutcome({ model, outcome, ...extra }, this.dir);
    const next = reduce(loadHealth(this.dir), { model, outcome }, this.now());
    saveHealth(next, this.dir);
    return next[model]!;
  }

  status(model: string) {
    const raw = this.rawModel(model);
    const profile = raw ? this.profileFor(toCandidate(raw)) : undefined;
    const h = loadHealth(this.dir)[model] ?? emptyHealth();
    const used = leaseCounts(this.dir, this.now())[model] ?? 0;
    return { model, known: !!raw, profile, health: h, cooling: isCooling(h, this.now()),
      leases: { used, capacity: profile ? profile.lease_capacity : null },
      observed: aggregate(model, readOutcomes(this.dir)) };
  }

  list() {
    const { candidates, excluded } = this.pool();
    const counts = leaseCounts(this.dir, this.now());
    const health = loadHealth(this.dir);
    const rows = candidates.map((c) => {
      const p = this.profileFor(c);
      const ratings = Object.entries(p.ratings).filter(([, r]) => r !== "unknown")
        .map(([k, r]) => `${k}=${r}(${p.source[k as Capability]})`).join(",");
      const h = health[c.key] ?? emptyHealth();
      return { key: c.key, free: p.free, ratings: ratings || "unrated", health: isCooling(h, this.now()) ? "cooling" : h.state,
        leases: `${counts[c.key] ?? 0}/${p.lease_capacity ?? "inf"}` };
    });
    return { rows, excluded };
  }

  /** Merge a curated profile entry. machine -> machineDir/profiles.json, project -> .statefulclanker/profiles.json */
  setProfile(p: { pattern: string; scope: "machine" | "project"; capabilities?: Partial<Record<Capability, Rating>>;
    quirks?: Record<string, unknown>; lease_capacity?: number }): string {
    const file = p.scope === "machine" ? join(this.dir, "profiles.json") : projectProfilesPath(this.o.root);
    let raw: any = {};
    if (existsSync(file)) { try { raw = JSON.parse(readFileSync(file, "utf8")); } catch { raw = {}; } }
    if (Array.isArray(raw)) throw new Error(`${file} is in array form; edit by hand`);
    const bucket = raw.profiles && typeof raw.profiles === "object" && !Array.isArray(raw.profiles) ? raw.profiles : raw;
    const prev = bucket[p.pattern] ?? {};
    const next: any = { ...prev };
    if (p.capabilities) next.capabilities = { ...(prev.capabilities ?? {}), ...p.capabilities };
    if (p.quirks) next.quirks = { ...(prev.quirks ?? {}), ...p.quirks };
    if (p.lease_capacity !== undefined) next.lease_capacity = p.lease_capacity;
    bucket[p.pattern] = next;
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, JSON.stringify(raw, null, 2));
    return file;
  }
}
