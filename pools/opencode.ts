/**
 * opencode pool adapter.
 *
 * Verified against local `opencode --version` (1.18.35) and `opencode run --help`:
 *   opencode run [message..] --format json --session <id> --dir <dir> [-m provider/model]
 * `--format json` emits one raw JSON event per line (events seen in the 1.18.35 binary:
 * `step_start`, `step_finish`, `text`, `tool_use`, each carrying `part` and usually `sessionID`).
 *
 * Session handling: a session id is allocated up front (opencode uses it as the continuation key),
 * and any id later reported on the stream is captured so a follow-up can reuse it. `--session` is a
 * resume switch, not a new-session switch, so passing a freshly generated id starts a new session.
 *
 * Safety: opencode has no per-run read-only flag. We deliberately never pass `--auto`; the CLI's
 * own permission deny-list is the only guard, so the caller is responsible for policy.
 *
 * Erasable TypeScript only.
 */
import type { ExternalWorkerSpec, ParsedPoolLine, PoolAdapter } from './types.ts';

const EVENT_TYPES = new Set(['step_start', 'step_finish', 'text', 'tool_use']);

/** Best-effort human text for one opencode event. Exported for unit tests. */
export function formatOpencodeEvent(evt: Record<string, unknown>): string {
  const type = typeof evt.type === 'string' ? evt.type : 'event';
  const part = (evt.part ?? {}) as Record<string, unknown>;
  if (type === 'text') {
    const text = typeof part.text === 'string' ? part.text : '';
    return text.replace(/\s+$/, '');
  }
  if (type === 'tool_use') {
    const tool = typeof part.tool === 'string' ? part.tool : 'tool';
    const state = (part.state ?? {}) as Record<string, unknown>;
    const title = typeof state.title === 'string' ? state.title : '';
    return title ? `· ${tool}: ${title}` : `· ${tool}`;
  }
  if (type === 'step_start') {
    return typeof part.snapshot === 'string' ? `… ${part.snapshot}` : '· step';
  }
  if (type === 'step_finish') {
    const reason = typeof part.reason === 'string' ? part.reason : 'done';
    return `· ${reason}`;
  }
  return `· ${type}`;
}

/** Extract a session id from any opencode event field we trust. */
export function sessionIdFromEvent(evt: Record<string, unknown>): string | undefined {
  for (const key of ['sessionID', 'session_id', 'sessionId']) {
    const value = evt[key];
    if (typeof value === 'string' && value.length > 0) return value;
  }
  const part = evt.part as Record<string, unknown> | undefined;
  if (part) {
    for (const key of ['sessionID', 'session_id', 'sessionId']) {
      const value = part[key];
      if (typeof value === 'string' && value.length > 0) return value;
    }
  }
  return undefined;
}

export const opencodeAdapter: PoolAdapter = {
  pool: 'opencode',
  kind: 'local',
  command: 'opencode',
  allocatesSession: true,
  resumeLabel: '--session',

  buildArgs(spec: ExternalWorkerSpec): string[] {
    const args = ['run', '--format', 'json'];
    if (spec.externalSessionId) args.push('--session', spec.externalSessionId);
    if (spec.model) args.push('-m', spec.model);
    args.push('--dir', spec.repo && spec.repo.length > 0 ? spec.repo : '.');
    // Positional message last; opencode treats trailing positionals as the message array.
    args.push(spec.assignment);
    return args;
  },

  parseLine(line: string): ParsedPoolLine {
    const trimmed = line.trim();
    if (trimmed.length === 0) return { text: '' };
    let evt: unknown;
    try {
      evt = JSON.parse(trimmed);
    } catch {
      return { text: trimmed };
    }
    if (evt === null || typeof evt !== 'object' || Array.isArray(evt)) {
      return { text: trimmed };
    }
    const record = evt as Record<string, unknown>;
    const sessionId = sessionIdFromEvent(record);
    const type = typeof record.type === 'string' ? record.type : '';
    const text = EVENT_TYPES.has(type) || type.length > 0 ? formatOpencodeEvent(record) : trimmed;
    return sessionId ? { text, sessionId } : { text };
  },
};
