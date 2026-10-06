import { existsSync, readFileSync } from "node:fs";
import type { Capability, CandidateModel, Profile, Quirks, Rating } from "./types.ts";
import { CAPABILITIES } from "./types.ts";
import type { Aggregate } from "./observations.ts";

export type Source = "derived" | "curated" | "observed" | "unknown";
export interface ResolvedProfile {
  ratings: Record<Capability, Rating>;
  source: Record<Capability, Source>;
  quirks: Quirks;
  free: boolean;
  lease_capacity: number | null; // null = unlimited
  family?: string;
}
export interface CuratedEntry extends Profile { layer: number; order: number }

export const RATING_ORDER: Record<Rating, number> = { unknown: -1, poor: 0, fair: 1, good: 2, excellent: 3 };
export const RATING_VALUE: Record<Rating, number> = { unknown: 0.35, poor: 0.1, fair: 0.5, good: 0.75, excellent: 1 };

export function isFree(m: CandidateModel): boolean {
  const c = m.cost;
  return c.input === 0 && c.output === 0 && c.cacheRead === 0 && c.cacheWrite === 0;
}

export function derive(m: CandidateModel): Partial<Record<Capability, Rating>> {
  const r: Partial<Record<Capability, Rating>> = {};
  r.vision = m.input.includes("image") ? "excellent" : "poor";
  r.long_context = m.contextWindow >= 400_000 ? "excellent" : m.contextWindow >= 128_000 ? "good"
    : m.contextWindow >= 32_000 ? "fair" : "poor";
  if (m.reasoning) r.reasoning = "good";
  return r;
}

export function globMatch(pattern: string, key: string): boolean {
  const re = new RegExp("^" + pattern.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$", "i");
  return re.test(key);
}

function readEntries(file: string | undefined, layer: number): CuratedEntry[] {
  if (!file || !existsSync(file)) return [];
  let raw: any;
  try { raw = JSON.parse(readFileSync(file, "utf8")); } catch { return []; }
  if (!raw || typeof raw !== "object") return [];
  const src = raw.profiles && typeof raw.profiles === "object" ? raw.profiles : raw;
  const out: CuratedEntry[] = [];
  let order = 0;
  if (Array.isArray(src)) {
    for (const e of src) if (e && typeof e.pattern === "string") out.push({ ...e, layer, order: order++ });
  } else {
    for (const [pattern, e] of Object.entries(src as Record<string, any>)) {
      out.push({ ...(e ?? {}), pattern, layer, order: order++ });
    }
  }
  return out;
}

/** machine/project are paths to profiles.json files. */
export function loadCurated(machine?: string, project?: string): CuratedEntry[] {
  return [...readEntries(machine, 0), ...readEntries(project, 1)];
}

function specificity(p: string): number { return p.replace(/\*/g, "").length; }

function matching(key: string, curated: CuratedEntry[]): CuratedEntry[] {
  return curated.filter((e) => globMatch(e.pattern, key)).sort((a, b) =>
    a.layer - b.layer || specificity(a.pattern) - specificity(b.pattern) || a.order - b.order);
}

function rateFromSuccess(rate: number): Rating {
  return rate >= 0.95 ? "excellent" : rate >= 0.8 ? "good" : rate >= 0.5 ? "fair" : "poor";
}
const STEPS: Rating[] = ["poor", "fair", "good", "excellent"];

export function resolveProfile(
  m: CandidateModel, curated: CuratedEntry[], observed?: Aggregate, minSamples = 8,
): ResolvedProfile {
  const ratings = {} as Record<Capability, Rating>;
  const source = {} as Record<Capability, Source>;
  for (const c of CAPABILITIES) { ratings[c] = "unknown"; source[c] = "unknown"; }
  for (const [c, r] of Object.entries(derive(m))) { ratings[c as Capability] = r; source[c as Capability] = "derived"; }
  let quirks: Quirks = {};
  let family = m.family;
  let lease: number | undefined;
  for (const e of matching(m.key, curated)) {
    for (const [c, r] of Object.entries(e.capabilities ?? {})) {
      if ((CAPABILITIES as readonly string[]).includes(c) && r) { ratings[c as Capability] = r; source[c as Capability] = "curated"; }
    }
    if (e.quirks) quirks = { ...quirks, ...e.quirks, known_issues: [...(quirks.known_issues ?? []), ...(e.quirks.known_issues ?? [])] };
    if (e.family) family = e.family;
    if (e.lease_capacity !== undefined) lease = e.lease_capacity;
  }
  if (observed) {
    for (const c of CAPABILITIES) {
      const t = observed.by_task_class[c] ?? (c === "coding" || c === "tool_use"
        ? { successes: observed.successes, failures: observed.failures } : undefined);
      if (!t) continue;
      const n = t.successes + t.failures;
      if (n === 0) continue;
      const sr = t.successes / n;
      if (n >= minSamples) { ratings[c] = rateFromSuccess(sr); source[c] = "observed"; }
      else if (ratings[c] !== "unknown") {
        const i = STEPS.indexOf(ratings[c]);
        const j = sr >= 0.9 ? Math.min(3, i + 1) : sr < 0.5 ? Math.max(0, i - 1) : i;
        ratings[c] = STEPS[j]!;
      }
    }
  }
  const free = isFree(m);
  const lease_capacity = lease !== undefined ? lease : free ? 1 : null;
  return { ratings, source, quirks, free, lease_capacity, family };
}
