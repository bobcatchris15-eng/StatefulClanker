import type { AbilityRequest, CandidateModel } from "./types.ts";
import { CAPABILITIES } from "./types.ts";
import { resolveAbility } from "./abilities.ts";
import { RATING_ORDER, RATING_VALUE, resolveProfile } from "./profiles.ts";
import type { ResolvedProfile } from "./profiles.ts";
import { isCooling } from "./health.ts";
import type { HealthMap } from "./health.ts";

export interface SelectContext {
  profiles: Record<string, ResolvedProfile>;
  health: HealthMap;
  leaseCounts: Record<string, number>;
  now: number;
  parentModelKey?: string;
  epsilon?: number;
}
export interface Ranked { key: string; score: number; suitability: number; diversityPenalty: number }
export interface SelectResult {
  chosen?: { key: string; provider: string; id: string; thinking: "high" | "medium" | undefined };
  reason: string;
  ranked: Ranked[];
  excluded: { key: string; why: string }[];
}

const PROVIDER_PENALTY = 0.1;
const FAMILY_PENALTY = 0.1;
const PREFER_BONUS = 0.02;

export function select(req: AbilityRequest, candidates: CandidateModel[], ctx: SelectContext): SelectResult {
  const ab = resolveAbility(req);
  const eps = ctx.epsilon ?? 0.05;
  const excluded: { key: string; why: string }[] = [];
  const byKey = new Map(candidates.map((c) => [c.key, c]));
  const profOf = (m: CandidateModel) => ctx.profiles[m.key] ?? resolveProfile(m, [], undefined);
  const avoid = new Set(req.avoid_provider ?? []);

  type Row = { m: CandidateModel; p: ResolvedProfile; suit: number; unrated: boolean };
  const rows: Row[] = [];
  for (const m of [...candidates].sort((a, b) => (a.key < b.key ? -1 : 1))) {
    const p = profOf(m);
    let why: string | undefined;
    if (avoid.has(m.provider)) why = `provider ${m.provider} avoided`;
    else if (req.free_only && !p.free) why = "not free";
    else if (p.ratings.tool_use === "poor") why = "tool_use rated poor";
    else if (req.min_context !== undefined && m.contextWindow < req.min_context)
      why = `context ${m.contextWindow} < ${req.min_context}`;
    else if (isCooling(ctx.health[m.key], ctx.now))
      why = `cooling until ${new Date(ctx.health[m.key]!.cooldown_until).toISOString()}`;
    else if (p.lease_capacity !== null && (ctx.leaseCounts[m.key] ?? 0) >= p.lease_capacity)
      why = `lease full (${ctx.leaseCounts[m.key] ?? 0}/${p.lease_capacity})`;
    else {
      for (const [c, min] of Object.entries(ab.min)) {
        const r = p.ratings[c as keyof typeof p.ratings];
        if (r !== "unknown" && min && RATING_ORDER[r] < RATING_ORDER[min]) { why = `${c} ${r} < min ${min}`; break; }
      }
    }
    if (why) { excluded.push({ key: m.key, why }); continue; }
    let sum = 0, wsum = 0, known = 0;
    for (const [c, w] of Object.entries(ab.weights)) {
      if (!w || !(CAPABILITIES as readonly string[]).includes(c)) continue;
      const r = p.ratings[c as keyof typeof p.ratings];
      sum += w * RATING_VALUE[r]; wsum += w; if (r !== "unknown") known++;
    }
    let suit = wsum ? sum / wsum : RATING_VALUE.unknown;
    if ((req.prefer_provider ?? []).includes(m.provider)) suit += PREFER_BONUS;
    rows.push({ m, p, suit, unrated: known === 0 });
  }

  const indep = req.independent_of ?? (ab.independent ? ctx.parentModelKey : undefined);
  const refs = [...(req.diversity_from ?? []), ...(indep ? [indep] : [])];
  const refProviders = new Set<string>(); const refFamilies = new Set<string>();
  for (const r of refs) {
    const rm = byKey.get(r);
    if (rm) { refProviders.add(rm.provider); const f = profOf(rm).family ?? rm.family; if (f) refFamilies.add(f); }
    else if (r.includes("/")) refProviders.add(r.split("/")[0]!);
    else refProviders.add(r);
  }
  const penalty = (r: Row): number => {
    if (indep === r.m.key) return PROVIDER_PENALTY + FAMILY_PENALTY;
    let p = 0;
    if (refProviders.has(r.m.provider)) p += PROVIDER_PENALTY;
    const f = r.p.family ?? r.m.family;
    if (f && refFamilies.has(f)) p += FAMILY_PENALTY;
    return p;
  };

  const order = (rs: Row[]): Ranked[] => {
    const sorted = [...rs].sort((a, b) => b.suit - a.suit || (a.m.key < b.m.key ? -1 : 1));
    if (!sorted.length) return [];
    const top = sorted[0]!.suit;
    const inSet = sorted.filter((r) => top - r.suit <= eps);
    const rest = sorted.slice(inSet.length);
    const scored = inSet.map((r) => ({ r, pen: penalty(r) }))
      .sort((a, b) => (b.r.suit - b.pen) - (a.r.suit - a.pen) || (a.r.m.key < b.r.m.key ? -1 : 1));
    return [
      ...scored.map(({ r, pen }) => ({ key: r.m.key, score: r.suit - pen, suitability: r.suit, diversityPenalty: pen })),
      ...rest.map((r) => ({ key: r.m.key, score: r.suit, suitability: r.suit, diversityPenalty: penalty(r) })),
    ];
  };
  const ranked = [...order(rows.filter((r) => !r.unrated)), ...order(rows.filter((r) => r.unrated))];

  if (!ranked.length) {
    const why = excluded.length ? excluded.map((e) => `${e.key}: ${e.why}`).join("; ") : "no candidates";
    return { reason: `no model fits: ${why}`, ranked, excluded };
  }
  const rk = ranked[0]!;
  const top = byKey.get(rk.key)!;
  const hi = req.profile === "architecture" || req.profile === "review";
  const thinking = top.reasoning ? (hi ? "high" : "medium") : undefined;
  const reason = `chose ${top.key}: suitability ${rk.suitability.toFixed(2)}, diversity penalty ${rk.diversityPenalty.toFixed(2)}` +
    ` among ${ranked.length} eligible, ${excluded.length} excluded`;
  return { chosen: { key: top.key, provider: top.provider, id: top.id, thinking }, reason, ranked, excluded };
}
