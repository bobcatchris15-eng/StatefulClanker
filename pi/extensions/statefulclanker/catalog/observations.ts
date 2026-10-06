import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { machineDir } from "./paths.ts";

export type OutcomeKind = "success" | "rate_limit" | "timeout" | "auth_error" | "malformed_tool_call"
  | "bad_continuation" | "tool_recovery" | "task_failure";
export interface Outcome {
  ts: string; model: string; outcome: OutcomeKind;
  task_class?: string; latency_ms?: number; worker_id?: string; note?: string;
}
export interface Aggregate {
  successes: number; failures: number;
  by_task_class: Record<string, { successes: number; failures: number }>;
  median_latency: number | null; success_rate: number | null;
}

export function observationsPath(dir = machineDir()): string { return join(dir, "observations.jsonl"); }

/** Only whitelisted fields are persisted; note is truncated. */
export function recordOutcome(o: Omit<Outcome, "ts"> & { ts?: string }, dir = machineDir()): void {
  mkdirSync(dir, { recursive: true });
  const rec: Outcome = { ts: o.ts ?? new Date().toISOString(), model: o.model, outcome: o.outcome };
  if (o.task_class) rec.task_class = o.task_class;
  if (o.latency_ms !== undefined) rec.latency_ms = o.latency_ms;
  if (o.worker_id) rec.worker_id = o.worker_id;
  if (o.note) rec.note = o.note.slice(0, 200);
  appendFileSync(observationsPath(dir), JSON.stringify(rec) + "\n");
}

export function readOutcomes(dir = machineDir()): Outcome[] {
  const f = observationsPath(dir);
  if (!existsSync(f)) return [];
  const out: Outcome[] = [];
  for (const line of readFileSync(f, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch { /* skip torn line */ }
  }
  return out;
}

export function aggregate(model: string, outcomes: Outcome[]): Aggregate {
  const a: Aggregate = { successes: 0, failures: 0, by_task_class: {}, median_latency: null, success_rate: null };
  const lat: number[] = [];
  for (const o of outcomes) {
    if (o.model !== model) continue;
    const ok = o.outcome === "success";
    if (ok) a.successes++; else a.failures++;
    if (o.task_class) {
      const t = (a.by_task_class[o.task_class] ??= { successes: 0, failures: 0 });
      if (ok) t.successes++; else t.failures++;
    }
    if (typeof o.latency_ms === "number") lat.push(o.latency_ms);
  }
  const n = a.successes + a.failures;
  if (n > 0) a.success_rate = a.successes / n;
  if (lat.length) {
    lat.sort((x, y) => x - y);
    const mid = lat.length >> 1;
    a.median_latency = lat.length % 2 ? lat[mid]! : (lat[mid - 1]! + lat[mid]!) / 2;
  }
  return a;
}
