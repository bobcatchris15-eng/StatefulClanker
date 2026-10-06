import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { machineDir } from "./paths.ts";
import type { OutcomeKind } from "./observations.ts";

export interface ModelHealth {
  state: "ok" | "cooling" | "failing";
  failure_streak: number;
  last_success: string | null;
  last_failure: string | null;
  cooldown_until: number; // epoch ms, 0 = none
  recent_failures: { ts: string; outcome: OutcomeKind }[];
}
export type HealthMap = Record<string, ModelHealth>;

export const BASE_COOLDOWN_MS = 60_000;
export const MAX_COOLDOWN_MS = 3_600_000;

export function emptyHealth(): ModelHealth {
  return { state: "ok", failure_streak: 0, last_success: null, last_failure: null, cooldown_until: 0, recent_failures: [] };
}

export function reduce(health: HealthMap, ev: { model: string; outcome: OutcomeKind }, now: number): HealthMap {
  const prev = health[ev.model] ?? emptyHealth();
  const h: ModelHealth = { ...prev, recent_failures: [...prev.recent_failures] };
  const iso = new Date(now).toISOString();
  if (ev.outcome === "success") {
    h.failure_streak = 0; h.cooldown_until = 0; h.state = "ok"; h.last_success = iso;
  } else {
    h.last_failure = iso;
    h.recent_failures.push({ ts: iso, outcome: ev.outcome });
    if (h.recent_failures.length > 10) h.recent_failures = h.recent_failures.slice(-10);
    if (ev.outcome === "rate_limit" || ev.outcome === "auth_error" || ev.outcome === "timeout") {
      h.failure_streak += 1;
      const cd = ev.outcome === "auth_error" ? MAX_COOLDOWN_MS
        : Math.min(MAX_COOLDOWN_MS, BASE_COOLDOWN_MS * 2 ** (h.failure_streak - 1));
      h.cooldown_until = now + cd;
      h.state = h.failure_streak >= 3 ? "failing" : "cooling";
    }
  }
  return { ...health, [ev.model]: h };
}

export function isCooling(h: ModelHealth | undefined, now: number): boolean {
  return !!h && h.cooldown_until > now;
}

export function healthPath(dir = machineDir()): string { return join(dir, "health.json"); }

export function loadHealth(dir = machineDir()): HealthMap {
  const f = healthPath(dir);
  if (!existsSync(f)) return {};
  try { return JSON.parse(readFileSync(f, "utf8")); } catch { return {}; }
}

export function saveHealth(map: HealthMap, dir = machineDir()): void {
  mkdirSync(dir, { recursive: true });
  const f = healthPath(dir);
  const tmp = `${f}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(tmp, JSON.stringify(map, null, 2));
  renameSync(tmp, f);
}
