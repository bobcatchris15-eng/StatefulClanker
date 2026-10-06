import { test } from "node:test";
import assert from "node:assert/strict";
import type { CandidateModel, Capability, Rating } from "../../catalog/types.ts";
import { resolveProfile } from "../../catalog/profiles.ts";
import type { CuratedEntry } from "../../catalog/profiles.ts";
import { reduce } from "../../catalog/health.ts";
import type { HealthMap } from "../../catalog/health.ts";
import { select } from "../../catalog/select.ts";
import type { SelectContext } from "../../catalog/select.ts";

function model(key: string, over: Partial<CandidateModel> = {}): CandidateModel {
  const [provider, ...rest] = key.split("/");
  return { key, provider: provider!, id: rest.join("/"), name: key, reasoning: false, input: ["text"],
    contextWindow: 200_000, maxTokens: 4000, cost: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 }, ...over };
}
type Caps = Partial<Record<Capability, Rating>>;
function setup(models: [CandidateModel, Caps?, Partial<CuratedEntry>?][], extra: Partial<SelectContext> = {}) {
  const curated: CuratedEntry[] = models.map(([m, caps, e], i) =>
    ({ pattern: m.key, capabilities: caps, layer: 0, order: i, ...(e ?? {}) }));
  const profiles: SelectContext["profiles"] = {};
  for (const [m] of models) profiles[m.key] = resolveProfile(m, curated);
  const ctx: SelectContext = { profiles, health: {}, leaseCounts: {}, now: 1_000_000, ...extra };
  return { cands: models.map(([m]) => m), ctx };
}
const GOOD: Caps = { coding: "good", tool_use: "good" };

test("hard filters report reasons", () => {
  const free = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  const health: HealthMap = reduce({}, { model: "c/cool", outcome: "rate_limit" }, 1_000_000);
  const { cands, ctx } = setup([
    [model("ok/fine"), GOOD],
    [model("t/nopool"), { coding: "good", tool_use: "poor" }],
    [model("s/small", { contextWindow: 8000 }), GOOD],
    [model("c/cool"), GOOD],
    [model("f/free", { cost: free }), GOOD],
    [model("av/avoided"), GOOD],
    [model("l/low"), { coding: "poor", tool_use: "good" }],
  ], { health, leaseCounts: { "f/free": 1 } });
  const r = select({ profile: "implementation", min_context: 100_000, avoid_provider: ["av"] }, cands, ctx);
  assert.equal(r.chosen?.key, "ok/fine");
  const why = Object.fromEntries(r.excluded.map((e) => [e.key, e.why]));
  assert.match(why["t/nopool"]!, /tool_use/);
  assert.match(why["s/small"]!, /context/);
  assert.match(why["c/cool"]!, /cooling/);
  assert.match(why["f/free"]!, /lease full/);
  assert.match(why["av/avoided"]!, /avoided/);
  assert.match(why["l/low"]!, /coding poor < min fair/);
  const fo = select({ profile: "implementation", free_only: true }, cands, { ...ctx, leaseCounts: {} });
  assert.deepEqual(fo.ranked.map((x) => x.key), ["f/free"]);
  assert.match(fo.excluded.find((e) => e.key === "ok/fine")!.why, /not free/);
});

test("unknown passes mins but ranks below rated", () => {
  const { cands, ctx } = setup([
    [model("a/unknown")],
    [model("z/rated"), { coding: "fair", tool_use: "fair" }],
  ]);
  const r = select({ profile: "implementation" }, cands, ctx);
  assert.deepEqual(r.ranked.map((x) => x.key), ["z/rated", "a/unknown"]);
  const only = select({ profile: "implementation" }, [cands[0]!], ctx);
  assert.equal(only.chosen?.key, "a/unknown");
});

test("diversity reorders only within epsilon", () => {
  const eq = setup([[model("openai/a"), GOOD], [model("anthropic/b"), GOOD]]);
  assert.equal(select({ profile: "implementation" }, eq.cands, eq.ctx).chosen?.key, "anthropic/b"); // tie -> key order
  const div = select({ profile: "implementation", diversity_from: ["openai"] }, eq.cands, eq.ctx);
  assert.equal(div.chosen?.key, "anthropic/b");
  const div2 = select({ profile: "implementation", diversity_from: ["anthropic"] }, eq.cands, eq.ctx);
  assert.equal(div2.chosen?.key, "openai/a");
  assert.ok(div2.ranked.find((x) => x.key === "anthropic/b")!.diversityPenalty > 0);
  const better = setup([
    [model("openai/a"), { coding: "excellent", tool_use: "excellent" }],
    [model("anthropic/b"), { coding: "good", tool_use: "good" }],
  ]);
  const r = select({ profile: "implementation", diversity_from: ["openai"] }, better.cands, better.ctx);
  assert.equal(r.chosen?.key, "openai/a");
});

test("explicit independence penalty, review uses parent, family counted", () => {
  const s = setup([
    [model("anthropic/a"), GOOD, { family: "claude" }],
    [model("openai/b"), GOOD],
  ], { parentModelKey: "anthropic/a" });
  const ex = select({ profile: "implementation", independent_of: "anthropic/a" }, s.cands, s.ctx);
  assert.equal(ex.chosen?.key, "openai/b");
  assert.equal(ex.ranked.find((x) => x.key === "anthropic/a")!.diversityPenalty, 0.2);
  const rev = setup([
    [model("anthropic/a"), { coding: "good", reasoning: "good" }],
    [model("openai/b"), { coding: "good", reasoning: "good" }],
  ], { parentModelKey: "anthropic/a" });
  const r = select({ profile: "review" }, rev.cands, rev.ctx);
  assert.equal(r.chosen?.key, "openai/b");
  const impl = select({ profile: "implementation" }, setup([[model("anthropic/a"), GOOD], [model("openai/b"), GOOD]],
    { parentModelKey: "anthropic/a" }).cands, rev.ctx);
  assert.equal(impl.ranked.every((x) => x.diversityPenalty === 0), true);
});

test("thinking level, prefer_provider, determinism", () => {
  const s = setup([
    [model("a/r", { reasoning: true }), { reasoning: "excellent", coding: "good", tool_use: "good" }],
    [model("b/n"), { reasoning: "poor", coding: "good", tool_use: "good" }],
  ]);
  assert.equal(select({ profile: "architecture" }, s.cands, s.ctx).chosen?.thinking, "high");
  assert.equal(select({ profile: "implementation" }, s.cands, s.ctx).chosen?.thinking, "medium");
  assert.equal(select({ profile: "implementation", prefer_provider: ["b"] }, s.cands, s.ctx).chosen?.key, "b/n");
  assert.equal(select({ profile: "implementation", prefer_provider: ["b"] }, s.cands, s.ctx).chosen?.thinking, undefined);
  const a = select({ profile: "fast" }, s.cands, s.ctx);
  const b = select({ profile: "fast" }, [...s.cands].reverse(), s.ctx);
  assert.deepEqual(a.ranked, b.ranked);
});

test("empty pool yields no chosen with all excluded reasons", () => {
  const { cands, ctx } = setup([[model("a/x"), GOOD], [model("b/y"), GOOD]], { leaseCounts: { "a/x": 0 } });
  const r = select({ profile: "implementation", avoid_provider: ["a", "b"] }, cands, ctx);
  assert.equal(r.chosen, undefined);
  assert.equal(r.excluded.length, 2);
  assert.match(r.reason, /a\/x: provider a avoided/);
  assert.match(r.reason, /b\/y/);
  assert.equal(select({}, [], ctx).chosen, undefined);
});
