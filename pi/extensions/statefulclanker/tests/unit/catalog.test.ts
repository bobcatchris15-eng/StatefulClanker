import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { CandidateModel } from "../../catalog/types.ts";
import { derive, globMatch, loadCurated, resolveProfile } from "../../catalog/profiles.ts";
import { aggregate, readOutcomes, recordOutcome } from "../../catalog/observations.ts";
import { loadHealth, reduce, saveHealth } from "../../catalog/health.ts";
import { machineDir, projectProfilesPath } from "../../catalog/paths.ts";

function model(key: string, over: Partial<CandidateModel> = {}): CandidateModel {
  const [provider, ...rest] = key.split("/");
  return { key, provider: provider!, id: rest.join("/"), name: key, reasoning: false, input: ["text"],
    contextWindow: 8000, maxTokens: 4000, cost: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 }, ...over };
}
const tmp = () => mkdtempSync(join(tmpdir(), "sc-cat-"));

test("derive ratings from model facts", () => {
  const r = derive(model("a/b", { input: ["text", "image"], contextWindow: 500_000, reasoning: true }));
  assert.equal(r.vision, "excellent");
  assert.equal(r.long_context, "excellent");
  assert.equal(r.reasoning, "good");
  assert.equal(derive(model("a/b")).vision, "poor");
  assert.equal(derive(model("a/b", { contextWindow: 128_000 })).long_context, "good");
  assert.equal(derive(model("a/b", { contextWindow: 32_000 })).long_context, "fair");
  assert.equal(derive(model("a/b")).long_context, "poor");
  assert.equal(derive(model("a/b")).reasoning, undefined);
});

test("machine dir honors SC_MACHINE_DIR", () => {
  const d = tmp();
  process.env.SC_MACHINE_DIR = d;
  assert.equal(machineDir(), d);
  delete process.env.SC_MACHINE_DIR;
  assert.ok(projectProfilesPath("/p").replace(/\\/g, "/").endsWith("/p/.statefulclanker/profiles.json"));
});

test("glob match, specificity and project override", () => {
  assert.ok(globMatch("openai/*", "openai/gpt-5"));
  assert.ok(!globMatch("openai/*", "xopenai/gpt"));
  assert.ok(globMatch("*/gpt-?", "a/gpt-?"));
  const d = tmp();
  const mf = join(d, "m.json"); const pf = join(d, "p.json");
  writeFileSync(mf, JSON.stringify({
    "openai/*": { capabilities: { coding: "fair" }, quirks: { known_issues: ["x"] } },
    "openai/gpt-5": { capabilities: { coding: "good", research: "good" } },
  }));
  writeFileSync(pf, JSON.stringify({ "openai/*": { capabilities: { coding: "excellent" }, lease_capacity: 3 } }));
  const m = model("openai/gpt-5");
  const machineOnly = resolveProfile(m, loadCurated(mf));
  assert.equal(machineOnly.ratings.coding, "good"); // specific pattern wins
  assert.equal(machineOnly.source.coding, "curated");
  assert.deepEqual(machineOnly.quirks.known_issues, ["x"]);
  const both = resolveProfile(m, loadCurated(mf, pf));
  assert.equal(both.ratings.coding, "excellent"); // project overrides
  assert.equal(both.ratings.research, "good");
  assert.equal(both.lease_capacity, 3);
  assert.equal(resolveProfile(m, []).ratings.coding, "unknown");
  assert.equal(resolveProfile(model("a/b", { cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }), []).lease_capacity, 1);
  assert.equal(resolveProfile(m, []).lease_capacity, null);
});

test("observed nudges below minSamples and dominates at minSamples", () => {
  const d = tmp();
  const m = model("p/m");
  const curated = [{ pattern: "p/m", capabilities: { coding: "good" as const }, layer: 0, order: 0 }];
  for (let i = 0; i < 7; i++) recordOutcome({ model: "p/m", outcome: "task_failure", latency_ms: 100 + i }, d);
  let agg = aggregate("p/m", readOutcomes(d));
  assert.equal(agg.failures, 7);
  assert.equal(agg.median_latency, 103);
  let r = resolveProfile(m, curated, agg, 8);
  assert.equal(r.ratings.coding, "fair"); // nudged down one step only
  assert.equal(r.source.coding, "curated");
  recordOutcome({ model: "p/m", outcome: "task_failure" }, d);
  recordOutcome({ model: "other/x", outcome: "success" }, d);
  agg = aggregate("p/m", readOutcomes(d));
  r = resolveProfile(m, curated, agg, 8);
  assert.equal(r.ratings.coding, "poor");
  assert.equal(r.source.coding, "observed");
  assert.equal(agg.success_rate, 0);
  const line = readFileSync(join(d, "observations.jsonl"), "utf8").split("\n")[0]!;
  assert.deepEqual(Object.keys(JSON.parse(line)).sort(), ["latency_ms", "model", "outcome", "ts"]);
});

test("health backoff, cap, reset, persistence", () => {
  const d = tmp();
  let h = reduce({}, { model: "p/m", outcome: "rate_limit" }, 1000);
  assert.equal(h["p/m"]!.cooldown_until, 1000 + 60_000);
  h = reduce(h, { model: "p/m", outcome: "timeout" }, 2000);
  assert.equal(h["p/m"]!.cooldown_until, 2000 + 120_000);
  h = reduce(h, { model: "p/m", outcome: "rate_limit" }, 3000);
  assert.equal(h["p/m"]!.failure_streak, 3);
  assert.equal(h["p/m"]!.state, "failing");
  for (let i = 0; i < 12; i++) h = reduce(h, { model: "p/m", outcome: "rate_limit" }, 4000);
  assert.equal(h["p/m"]!.cooldown_until, 4000 + 3_600_000);
  assert.equal(h["p/m"]!.recent_failures.length, 10);
  h = reduce(h, { model: "q/m", outcome: "auth_error" }, 0);
  assert.equal(h["q/m"]!.cooldown_until, 3_600_000);
  h = reduce(h, { model: "p/m", outcome: "malformed_tool_call" }, 5000);
  assert.ok(h["p/m"]!.failure_streak > 3); // non-cooldown outcome leaves streak alone
  h = reduce(h, { model: "p/m", outcome: "success" }, 6000);
  assert.equal(h["p/m"]!.failure_streak, 0);
  assert.equal(h["p/m"]!.cooldown_until, 0);
  assert.equal(h["p/m"]!.state, "ok");
  saveHealth(h, d);
  assert.deepEqual(loadHealth(d), h);
  mkdirSync(join(d, "x"), { recursive: true });
  rmSync(d, { recursive: true, force: true });
});
