/**
 * Google Jules pool adapter (cloud, patch-on-pull — NOT a local child process).
 *
 * Verified locally against `jules --help`, `jules new --help`, `jules remote list --help`,
 * `jules remote pull --help`:
 *   jules new "<prompt>" [--repo owner/name] [--parallel 1-5]
 *   jules remote list --session
 *   jules remote pull --session <id> [--apply]
 *   jules teleport <id>
 *
 * There is no long-lived process to supervise, so the one-shot `PoolAdapter.buildArgs` shape is
 * driven in phases via `metadata.phase` (see {@link julesAdapter}). The registry runs
 * `dispatch` -> poll `status` (repeated) -> `pull` (`--apply`) -> `done`. See [[jules-cloud-pool]].
 *
 * `jules --version` is not a valid flag, so {@link julesVersionArgs} uses `jules --help` head.
 *
 * Erasable TypeScript only.
 */
import type { ExternalWorkerSpec, ParsedPoolLine, PoolAdapter } from './types.ts';

/** Lifecycle phase of one Jules job. Jules runs in a cloud VM; the local side only orchestrates. */
export type JulesPhase = 'dispatch' | 'status' | 'pull' | 'teleport';

/** Read `metadata.phase` off a spec, defaulting to `dispatch`. */
export function julesPhase(spec: ExternalWorkerSpec): JulesPhase {
  const raw = (spec.metadata ?? {}).phase;
  return raw === 'status' || raw === 'pull' || raw === 'teleport' ? raw : 'dispatch';
}

/** Session id (`spec.externalSessionId`) is mandatory for every phase except `dispatch`. */
function requireSession(spec: ExternalWorkerSpec, phase: JulesPhase): string {
  const id = spec.externalSessionId;
  if (!id) throw new Error(`jules ${phase} requires a session id; dispatch returned none`);
  return id;
}

/**
 * `--repo owner/name`. Omitted means "the cwd's repository", which is what we want: Jules codes
 * against the pushed commit of the repo we are standing in. The registry surfaces unpushed-commit
 * drift separately rather than silently defaulting somewhere else.
 */
function repoArg(spec: ExternalWorkerSpec, args: string[]): void {
  const extra = (spec.metadata ?? {}) as Record<string, unknown>;
  const repo = typeof extra.repo === 'string' && extra.repo.length > 0 ? extra.repo : spec.repo;
  // Only pass --repo if it looks like owner/name (no colon, exactly one slash, no backslashes)
  if (typeof repo === 'string' && !repo.includes(':') && !repo.includes('\\') && (repo.match(/\//g) || []).length === 1) {
    args.push('--repo', repo);
  }
}

/** Best-effort session id from `jules new` / `jules remote list` stdout. Exported for tests. */
export function sessionIdFromJulesText(text: string): string | undefined {
  // Observed shapes: a bare id line, `"sessionId": "..."`, `Session 12345 ...`, `id: 123`.
  const json = /"session[_-]?id"\s*:\s*"?([A-Za-z0-9_-]+)"?/i.exec(text);
  if (json?.[1]) return json[1];
  const labelled = /\b(?:session|id)\b\D{0,4}([0-9]{4,})\b/i.exec(text);
  if (labelled?.[1]) return labelled[1];
  const bare = /(?:^|\s)([0-9]{6,})(?:\s|$)/.exec(text);
  if (bare?.[1]) return bare[1];
  const slug = /\bsess(?:ion)?[-_]([A-Za-z0-9]{6,})\b/i.exec(text);
  return slug?.[1];
}

/** One-line human rendering for `jules remote list --session` rows. */
export function formatJulesSessionRow(text: string): string {
  const state = /\b(in_progress|working|queued|pending|completed|done|failed|error|awaiting)\b/i.exec(text);
  const id = sessionIdFromJulesText(text);
  const parts: string[] = [];
  if (id) parts.push(id);
  if (state?.[1]) parts.push(state[1].toLowerCase());
  return parts.length > 0 ? parts.join(' · ') : text.trim();
}

export const julesAdapter: PoolAdapter = {
  pool: 'jules',
  kind: 'cloud',
  command: 'jules',
  // Jules allocates the session id itself on `jules new`; there is no caller-supplied session switch.
  allocatesSession: false,
  resumeLabel: '--session (jules-allocated, not resumable)',

  buildArgs(spec: ExternalWorkerSpec): string[] {
    const extra = (spec.metadata ?? {}) as Record<string, unknown>;
    const phase = julesPhase(spec);
    if (phase === 'dispatch') {
      const args = ['new'];
      repoArg(spec, args);
      const parallel = typeof extra.parallel === 'number' ? extra.parallel : 1;
      if (parallel > 1) args.push('--parallel', String(Math.min(5, Math.max(1, Math.round(parallel)))));
      args.push(spec.assignment);
      return args;
    }
    if (phase === 'status') {
      const session = requireSession(spec, phase);
      // `jules remote list --session` enumerates all sessions; filtering is a display concern, so
      // we filter in the registry rather than passing an unsupported flag.
      return ['remote', 'list', '--session'];
    }
    if (phase === 'teleport') {
      return ['teleport', requireSession(spec, phase)];
    }
    const args = ['remote', 'pull', '--session', requireSession(spec, phase)];
    // `--apply` is the single write to the shared tree. It is opt-in per run so a plain preview pull
    // (which prints the patch) stays available; it is not a safety gate, just an explicit action.
    if (extra.apply !== false) args.push('--apply');
    return args;
  },

  parseLine(line: string): ParsedPoolLine {
    const trimmed = line.trim();
    if (trimmed.length === 0) return { text: '' };
    const sessionId = sessionIdFromJulesText(trimmed);
    const looksLikeRow = /\b(in_progress|working|queued|pending|completed|done|failed|error)\b/i.test(trimmed);
    if (looksLikeRow) {
      const text = formatJulesSessionRow(trimmed);
      return sessionId ? { text, sessionId, kind: 'progress' } : { text, kind: 'progress' };
    }
    return sessionId ? { text: trimmed, sessionId, kind: 'progress' } : { text: trimmed, kind: 'progress' };
  },
};

/** Version probe args: `jules --version` does not exist. */
export const julesVersionArgs: string[] = ['--help'];

/** True when a pulled/listed session state means the cloud run is finished and pullable. */
export function julesSessionFinished(text: string): boolean {
  return /\b(completed|done|finished|failed|error)\b/i.test(text);
}