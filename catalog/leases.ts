import { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { machineDir } from "./paths.ts";

export interface Lease {
  lease_id: string; model: string; worker_id: string; parent_pid: number;
  claimed_at: number; expires_at: number;
}
export interface LeaseOwner { worker_id: string; parent_pid: number }

const LOCK_STALE_MS = 10_000;
const LOCK_TIMEOUT_MS = 2_000;

function sleep(ms: number): void { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

function withLock<T>(dir: string, fn: () => T): T {
  mkdirSync(dir, { recursive: true });
  const lock = join(dir, "leases.lock");
  const start = Date.now();
  let delay = 5;
  for (;;) {
    try { closeSync(openSync(lock, "wx")); break; } catch (e: any) {
      if (e?.code !== "EEXIST" && e?.code !== "EPERM" && e?.code !== "EACCES") throw e;
      try { if (Date.now() - statSync(lock).mtimeMs > LOCK_STALE_MS) { unlinkSync(lock); continue; } } catch { /* raced */ }
      if (Date.now() - start > LOCK_TIMEOUT_MS) throw new Error("lease lock timeout");
      sleep(delay); delay = Math.min(delay * 2, 100);
    }
  }
  try { return fn(); } finally { try { unlinkSync(lock); } catch { /* ignore */ } }
}

function read(dir: string): Lease[] {
  const f = join(dir, "leases.json");
  if (!existsSync(f)) return [];
  try { const v = JSON.parse(readFileSync(f, "utf8")); return Array.isArray(v) ? v : []; } catch { return []; }
}
function write(dir: string, leases: Lease[]): void {
  const f = join(dir, "leases.json");
  const tmp = `${f}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(leases, null, 2));
  renameSync(tmp, f);
}

export function claim(model: string, owner: LeaseOwner, capacity: number | null, ttlMs: number,
  dir = machineDir(), now = Date.now()): Lease | null {
  return withLock(dir, () => {
    const live = read(dir).filter((l) => l.expires_at > now);
    const n = live.filter((l) => l.model === model).length;
    if (capacity !== null && n >= capacity) { write(dir, live); return null; }
    const lease: Lease = { lease_id: randomUUID(), model, worker_id: owner.worker_id,
      parent_pid: owner.parent_pid, claimed_at: now, expires_at: now + ttlMs };
    write(dir, [...live, lease]);
    return lease;
  });
}

export function release(leaseId: string, dir = machineDir()): boolean {
  return withLock(dir, () => {
    const all = read(dir); const rest = all.filter((l) => l.lease_id !== leaseId);
    write(dir, rest); return rest.length !== all.length;
  });
}

export function releaseByWorker(workerId: string, dir = machineDir()): number {
  return withLock(dir, () => {
    const all = read(dir); const rest = all.filter((l) => l.worker_id !== workerId);
    write(dir, rest); return all.length - rest.length;
  });
}

export function reapDead(isAlive: (pid: number) => boolean, dir = machineDir(), now = Date.now()): number {
  return withLock(dir, () => {
    const all = read(dir);
    const rest = all.filter((l) => l.expires_at > now && isAlive(l.parent_pid));
    write(dir, rest); return all.length - rest.length;
  });
}

export function activeCount(model: string, dir = machineDir(), now = Date.now()): number {
  return withLock(dir, () => read(dir).filter((l) => l.model === model && l.expires_at > now).length);
}

export function leaseCounts(dir = machineDir(), now = Date.now()): Record<string, number> {
  return withLock(dir, () => {
    const c: Record<string, number> = {};
    for (const l of read(dir)) if (l.expires_at > now) c[l.model] = (c[l.model] ?? 0) + 1;
    return c;
  });
}
