/**
 * Shared types for external worker pools (opencode, agy, Google Jules).
 *
 * A "pool" is an execution source unrelated to native Pi workers: its own CLI, its own model
 * catalogue, its own lifecycle and its own receipts. The orchestrator treats each pool as a
 * separate pool rather than pretending they can share the Pi worker runtime.
 *
 * This module is types + two tiny seams only. Adapters describe argv; the runner owns process
 * lifecycle; {@link ./state.ts} owns the store. See [[external-agent-pools]] and [[pool-pane]].
 *
 * Erasable TypeScript only (no enums, no namespaces, no parameter properties).
 */

/** Which family of CLI a pool drives. */
export type PoolKind = 'local' | 'cloud';

/** The three external pools, as owned by the orchestrator. Native Pi workers are not a pool. */
export type ExternalPoolId = 'opencode' | 'agy' | 'jules';

/**
 * Lifecycle of one pool job. Distinct from native Pi worker status on purpose.
 *
 * `streaming` means the CLI is alive and emitting normalized output; `waiting_input` means it is
 * alive but blocked (an unanswered prompt, for example) and will hit the timeout if nothing happens.
 */
export type PoolWorkerStatus =
  | 'queued'
  | 'starting'
  | 'running'
  | 'streaming'
  | 'waiting_input'
  | 'succeeded'
  | 'failed'
  | 'cancelled'
  | 'timeout'
  | 'lost';

/** Status alias used by receipts and panes. */
export type PoolRunStatus = PoolWorkerStatus;

/** One normalized event from a pool run. */
export type PoolEvent =
  | { type: 'text'; text: string }
  | { type: 'progress'; line: string }
  | { type: 'tool'; name: string; detail?: string }
  | { type: 'session'; id: string }
  | { type: 'exit'; code: number | null; signal: string | null; timedOut: boolean; cancelled: boolean };

export type PoolEventListener = (event: PoolEvent) => void;

/** Result of normalizing one raw CLI output line. */
export interface ParsedPoolLine {
  /** Human-facing one-line rendering; `''` means "nothing worth showing". */
  text: string;
  /** Session/conversation id observed on the stream, if any. */
  sessionId?: string;
  /** Event kind, when the adapter can tell (lets the runner upgrade `text` to `tool`/`session`). */
  kind?: 'text' | 'tool' | 'progress';
  /** Tool name when `kind === 'tool'`. */
  tool?: string;
}

/**
 * What the orchestrator asks a pool to run, plus the registry's current view of it.
 *
 * One shape on purpose: the store snapshots this verbatim to `<id>.json`, so a restart can
 * reconcile a run whose process is gone (see `PoolStore.readStale`).
 */
export interface ExternalWorkerSpec {
  /** Registry id, unique per pool job. Also the store's filename stem. */
  id: string;
  /** Pool identity. */
  pool: ExternalPoolId;
  /** Current lifecycle state. */
  status: PoolWorkerStatus;
  /** The full assignment/prompt handed to the CLI. */
  assignment: string;
  /** Repository root the pool works in. */
  repo?: string;
  /** Optional provider/model hint (`provider/id` where the CLI accepts one). */
  model?: string;
  /** Resume key, when the pool supports one. */
  externalSessionId?: string;
  /** Pool-specific options (see each adapter's `buildArgs`). */
  metadata?: Record<string, unknown>;
  startedAt?: number;
  endedAt?: number;
  exitCode?: number | null;
  /** Files the run reported touching. Advisory only: direct-write autonomy gates nothing. */
  touchedPaths?: string[];
  note?: string;
}

/** Static description of a pool CLI. Adapters are pure data + pure functions. */
export interface PoolAdapter {
  pool: ExternalPoolId;
  kind: PoolKind;
  /** Executable name or absolute path. */
  command: string;
  /**
   * True when the CLI accepts a caller-supplied session id at spawn time (opencode's `--session`).
   * False means the pool has no resume switch and each job starts fresh (agy; see [[agy-pool]]).
   */
  allocatesSession: boolean;
  /** Human label for the resume switch, for receipts and error messages. */
  resumeLabel: string;
  buildArgs(spec: ExternalWorkerSpec): string[];
  parseLine(line: string): ParsedPoolLine;
}

/** Durable receipt for one pool job: what was dispatched, and what came back. */
export interface ExternalWorkerSummary {
  id: string;
  pool: ExternalPoolId;
  status: PoolRunStatus;
  /** Model/provider actually requested, if the CLI reported or accepted one. */
  model?: string;
  /** Session/conversation id, when the pool reported one. */
  externalSessionId?: string;
  /** Files the run reported touching. Advisory only: direct-write autonomy means nothing is gated. */
  touchedPaths?: string[];
  startedAt?: number;
  endedAt?: number;
  exitCode?: number | null;
  /** True when the run ended because a timeout fired (distinct from a failure). */
  timedOut?: boolean;
  /** Short failure/timeout text for the pane. */
  note?: string;
}

/** Probe result for one pool CLI. Never throws; a missing binary is just `available: false`. */
export type PoolAvailability = {
  pool: ExternalPoolId;
  command: string;
  available: boolean;
  /** First stdout line of the version probe, when it produced one. */
  version?: string;
  reason?: string;
};

/** Minimal child-process shape the lifecycle uses, so tests can fake a process. */
export interface PoolChild {
  readonly pid?: number | null;
  kill(signal?: string): boolean;
  onClose(cb: (code: number | null, signal?: string | null) => void): void;
  onError(cb: (err: unknown) => void): void;
  readonly stdout: NodeJS.ReadableStream;
  readonly stderr: NodeJS.ReadableStream;
}

/** Test seam: injected spawner. Defaults to `node:child_process.spawn`. */
export type SpawnFn = (
  command: string,
  args: string[],
  opts: { cwd: string; env?: Record<string, string | undefined>; stdio?: unknown; windowsHide?: boolean },
) => PoolChild;