import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { operatorMode } from './operator.ts';
import { workerMode } from './worker.ts';

export const LOADED_KEY = Symbol.for('statefulclanker.loaded');

/** Returns true if this call is the first load in the process (and marks it). */
export function claimLoad(g: Record<symbol, unknown> = globalThis as any): boolean {
  if (g[LOADED_KEY]) return false;
  g[LOADED_KEY] = true;
  return true;
}

export default function (pi: ExtensionAPI): void {
  if (!claimLoad()) return;
  if (process.env.SC_WORKER_ID) workerMode(pi);
  else operatorMode(pi);
}
