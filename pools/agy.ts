/**
 * agy pool adapter.
 *
 * Verified against local `agy --version` (1.3.3) and `agy --help`:
 *   agy --print "<prompt>" --output-format stream-json --mode plan
 *       [--conversation <id>] [--model M] [--agent A] [--effort low|medium|high|xhigh|max]
 *       [--add-dir DIR] [--project P] [--print-timeout 0] [--sandbox]
 *
 * IMPORTANT: there is NO `agy exec` subcommand. Headless mode is print mode (`--print`, alias `-p`).
 * The only real subcommands are: agent(s), changelog, help, install, mcp, mic-serve, models,
 * plugin(s), remote-control, update.
 *
 * Session model: unlike opencode/pi, agy does not take a caller-supplied session id at spawn time.
 * This adapter therefore does NOT allocate one (`allocatesSession: false`); the runner starts each
 * job with no id and captures a conversation id if agy reports one on the stream. When an id has
 * been captured, `--conversation <id>` resumes it (this is optional capability; the pool works
 * without resume). See [[external-agent-pools]].
 *
 * Default mode is `accept-edits` (do real work) per human intent i-0002 / i-0004; `plan` is an explicit
 * per-task opt-in. The caller may override `mode`; `--sandbox` is forwarded when supplied.
 * `--print-timeout 0` means "no CLI-side limit", so
 * the pool enforces its own timeout instead.
 *
 * Erasable TypeScript only.
 */
import type { ExternalWorkerSpec, ParsedPoolLine, PoolAdapter } from './types.ts';

function firstString(record: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === 'string' && value.length > 0) return value;
  }
  return undefined;
}

function nestedText(value: unknown): string | undefined {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    const parts: string[] = [];
    for (const item of value) {
      const text = nestedText(item);
      if (text) parts.push(text);
    }
    return parts.length > 0 ? parts.join('') : undefined;
  }
  if (value !== null && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    return firstString(record, ['text', 'content', 'message', 'delta']);
  }
  return undefined;
}

/** Best-effort human text for one agy stream-json event. Exported for unit tests. */
export function formatAgyEvent(evt: Record<string, unknown>): string {
  const type = firstString(evt, ['type', 'event']) ?? 'event';
  if (type === 'tool_use' || type === 'tool_result') {
    const tool = firstString(evt, ['name', 'tool', 'tool_name']) ?? 'tool';
    return `· ${type}: ${tool}`;
  }
  const direct = nestedText(evt.text ?? evt.content ?? evt.delta ?? evt.message);
  if (direct !== undefined) return direct.replace(/\s+$/, '');
  const part = evt.part ?? evt.item;
  const fromPart = nestedText(part);
  if (fromPart !== undefined) return fromPart.replace(/\s+$/, '');
  if (type === 'result') {
    const result = firstString(evt, ['result', 'summary', 'status']);
    return result ? `· ${result}` : '· result';
  }
  if (type === 'message_start') return '· start';
  if (type === 'message_stop' || type === 'end_turn') return '· done';
  return `· ${type}`;
}

/** Extract an agy conversation/session id from any stream event we trust. */
export function conversationIdFromEvent(evt: Record<string, unknown>): string | undefined {
  const direct = firstString(evt, [
    'conversationId',
    'conversation_id',
    'sessionId',
    'session_id',
  ]);
  if (direct) return direct;
  const nested = evt.conversation ?? evt.session;
  if (nested !== null && typeof nested === 'object') {
    const record = nested as Record<string, unknown>;
    return firstString(record, ['id', 'conversationId', 'conversation_id', 'sessionId', 'session_id']);
  }
  return undefined;
}

export const agyAdapter: PoolAdapter = {
  pool: 'agy',
  kind: 'local',
  command: 'agy',
  allocatesSession: false,
  resumeLabel: '--conversation',

  buildArgs(spec: ExternalWorkerSpec): string[] {
    const extra = (spec.metadata ?? {}) as Record<string, unknown>;
    const args = ['--print', spec.assignment, '--output-format', 'stream-json'];
    // Human intent i-0002 / i-0004: AGY does real work by default. `accept-edits` is the mode in which
    // it actually edits the tree; `plan` is a per-task opt-in ONLY and must never be used as a way to
    // dodge permission prompts.
    const mode = typeof extra.mode === 'string' ? extra.mode : 'accept-edits';
    args.push('--mode', mode);
    if (typeof extra.effort === 'string') args.push('--effort', extra.effort);
    if (typeof extra.agent === 'string') args.push('--agent', extra.agent);
    if (typeof extra.project === 'string') args.push('--project', extra.project);
    const addDirs = Array.isArray(extra.addDir)
      ? extra.addDir.filter((d): d is string => typeof d === 'string')
      : typeof extra.addDir === 'string'
        ? [extra.addDir]
        : [];
    for (const dir of addDirs) args.push('--add-dir', dir);
    if (extra.sandbox === true) args.push('--sandbox');
    if (spec.externalSessionId) args.push('--conversation', spec.externalSessionId);
    if (spec.model) args.push('--model', spec.model);
    // A headless agy run can hang forever on an unanswered tool-permission prompt, so the CLI-side
    // limit is non-zero by default (intent i-0004). Callers may override it; `0` (no limit) is now an
    // explicit opt-in, not the default.
    args.push('--print-timeout', typeof extra.printTimeout === 'string' ? extra.printTimeout : '10m');
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
    const sessionId = conversationIdFromEvent(record);
    const text = formatAgyEvent(record);
    return sessionId ? { text, sessionId } : { text };
  },
};
