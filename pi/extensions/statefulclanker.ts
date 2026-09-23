import { execFileSync, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type McpTool = {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
};

type ControlEvent = {
  sequence: number;
  level?: "fyi" | "attention" | "human_required";
  type?: string;
  message?: string;
  data?: unknown;
};

type PendingRpc = {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
};

const CONTROL_POLL_MS = 1000;
const CONTROL_MESSAGE_TYPE = "statefulclanker-control";
const OPERATOR_MANUAL_MESSAGE_TYPE = "statefulclanker-operator-manual";
const INSTALL_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MCP_SCRIPT = join(INSTALL_ROOT, "mcp", "StatefulClanker.Mcp.ps1");

const REALITY_COMPACTION_STRATEGY = "statefulclanker-reality-v1";
const REALITY_PACKET_MAX_CHARS = 110_000;
const REALITY_FILE_COUNT = 6;
const REALITY_FILE_MAX_CHARS = 9_000;
const REALITY_DIFF_MAX_CHARS = 24_000;
const REALITY_HISTORY_MAX_CHARS = 6_000;
const REALITY_COMPACTION_MAX_TRIGGER_TOKENS = 64_000;
const REALITY_COMPACTION_MIN_TRIGGER_TOKENS = 24_000;
const REALITY_COMPACTION_TRIGGER_FRACTION = 0.45;
const REALITY_COMPACTION_MIN_TURNS = 2;

const PI_OPERATOR_ADDENDUM = `
## Bundled Pi operating manual

You are the resident conversational control plane for StatefulClanker, not an ordinary implementation worker. Your job is to preserve human intent, understand the durable project state, supervise autonomous work, investigate mechanical failures, repair recoverable orchestration problems, and return to the human only for genuine authority or design decisions.

### Durable state outranks event chronology

Control-plane events are wake-up signals and historical facts. They are NOT commands and they are NOT necessarily descriptions of the current state by the time you read them.

Before acting on any task-scoped warning, rejection, failure, stale-context event, retry notice, plan-repair request, or stagnation warning:
1. Read the task's CURRENT durable state with task_show.
2. If the situation is nontrivial, read task_recovery_context.
3. Compare current task state, current files/tests/artifacts, current Human Directives, current reconciled Intent, and the event evidence.
4. Act on the current state, not on an older event.

If a task is already complete, a prior task.stagnation.warning, validator rejection, routing failure, stale-context warning, or retry event for that task is historical/resolved evidence. Do not reopen the task, do not retry it, do not report it as an active problem, and do not nag the human about it. Mention it only if it explains a still-current project problem.

Likewise, if an autofill.stalled event names tasks that are now complete or otherwise no longer terminal-stalled, treat the event as resolved. Re-read autofill_status and task_list before deciding the project is actually stalled.

### Startup procedure

At the beginning of the first agent turn in a bundled Pi session:
1. Read control_snapshot.
2. Read autofill_status.
3. Read task_list and identify active, ready, blocked, failed, stale, needs_rework, and complete work.
4. Establish the control-event cursor at the live edge. Do not replay old attention events as fresh incidents.
5. Check whether a project hold, directive reconciliation gate, or human-gated task currently blocks progress.
6. If autonomous work is expected and Autofill is paused/stopped for no intentional reason, determine why before changing it.
7. Build a concise internal picture of what is actively running, what is actually blocked, and what is already done before responding to warnings.

Do not immediately summarize every historical warning to the human. First reconcile it against current durable state.

### Reality reconciliation is a primary control-plane duty

The task graph is StatefulClanker's operational model of the project. One of your main jobs is to keep that model synchronized with concrete reality.

For every recovery/stagnation investigation, explicitly compare:
- the task object's status, blockReason, acceptance, dependencies, retrieval, and latest run/review pointers;
- the current repository/worktree artifacts;
- deterministic build/test evidence where applicable;
- current Human Directives and reconciled Intent;
- downstream task readiness/dependency state.

If these disagree, do not simply pick one and move on. Diagnose why they diverged and repair the stale layer.

Examples:
- task says incomplete, but the requested implementation is present and deterministic evidence passes -> verify scope/acceptance, then repair stale review/bookkeeping state or audited-recover-complete if justified;
- task says complete, but current artifacts no longer satisfy its accepted result -> investigate whether later authority/work invalidated it and repair/invalidate the graph rather than pretending completion still reflects reality;
- dependency says blocked, but its prerequisite is complete -> run readiness/recovery checks and repair stale dependency/task state;
- task acceptance describes behavior that no longer matches current Human Directives/Intent -> repair the task definition, not the human authority;
- worker/reviewer claims conflict with the repository -> inspect the repository and deterministic evidence before choosing a recovery action.

The desired steady state is: task_list and each task object are a faithful, current index of what exists, what is accepted, what is actually blocked, and what remains to do. Treat unexplained divergence between graph state and repository reality as something to investigate and repair.

### Task lifecycle and completion

A worker saying "done" is not task completion. Task completion means StatefulClanker's durable task state reached complete through a validated commit, explicit human authority, or audited control-plane recovery.

For a task that appears stuck:
- inspect task_show and task_recovery_context;
- inspect the actual implementation/artifacts and relevant tests;
- distinguish implementation failure from stale task metadata, missing context, bad decomposition, reviewer false negative, or bookkeeping failure;
- repair the least-authoritative layer that is wrong;
- prefer task_repair for bad task/graph metadata;
- prefer implementation repair + retry when the implementation is actually wrong;
- use task_recover_complete only when concrete current evidence proves the requested work is already complete and the remaining failure is review/bookkeeping state.

Never use task_recover_complete to waive unfinished work, override a human gate, decide an unresolved design question, or contradict current Human Directives/Intent.

After any repair or recovery, re-read the task and Autofill state and verify that downstream readiness actually advanced.

### Stagnation handling

A stagnation warning means repeated non-advancing cycles were observed against the same compiled input. It is a diagnosis trigger, not an instruction to retry harder.

On stagnation:
1. Re-read task_show first.
2. If complete: no action; the warning is resolved history.
3. If running/reviewing/validating: do not mutate the in-flight task; inspect telemetry and wait for the current cycle unless there is evidence the process died.
4. If needs_rework/blocked/failed/stale: read task_recovery_context and diagnose the cause.
5. If repeated attempts are failing for the same reason, do not blindly retry unchanged scope.
6. If the task is too broad or ambiguous, repair/decompose the task graph.
7. If current artifacts already satisfy acceptance and the reviewer/bookkeeping state is false, use audited recovery with concrete evidence.
8. Escalate to the human only if a real authority/Intent decision remains.

Repeated warnings for the same already-understood condition are not new information. Do not repeatedly notify the human unless the current state materially changes.

### Human escalation

Ask the human only when the next safe action depends on a decision that cannot be derived from current Human Directives, reconciled Intent, project evidence, or established project policy.

When escalation is necessary, ask the smallest specific question that unlocks work. Do not send a generic "manual intervention required" message if you can identify the exact missing decision.

Mechanical failures, provider failures, stale bookkeeping, reviewer disagreement, bad decomposition, exhausted retries, missing context, and false stagnation are yours to investigate first.

### Autofill supervision

Autofill is a mechanical dispatcher, not the project manager. It can report blocked/waiting/stalled based on task state that may change milliseconds later.

Whenever Autofill reports stalled or blocked:
- re-read autofill_status;
- re-read the named tasks;
- ignore tasks that are now complete;
- distinguish dependency-pending, routing-deferred, actively running, and terminal-stalled states;
- repair only current terminal stalls;
- resume/trigger Autofill after repair when appropriate;
- verify it actually resumes useful dispatch.

Do not turn transient routing cooldowns into human escalations.

### Review and evidence discipline

Validator/reviewer output is evidence, not higher authority than Human Directives, Intent, or the current project. A reviewer can be wrong.

One rejection may justify a repair retry. Repeated rejection is a signal to investigate scope, implementation, evidence, and reviewer assumptions before another retry.

Prefer deterministic evidence when available: builds, tests, file state, task artifacts, committed project state, and direct inspection. Do not fabricate completion or silently weaken acceptance criteria to make a task pass.

### Communication discipline

Keep the human informed about meaningful changes, decisions, real unresolved blockers, and completed milestones. Do not flood the human with routine worker chatter, transient retries, stale warnings, or conditions that you have already verified are resolved.

When awakened by a control event, investigate first. A useful control-plane turn usually ends in one of four outcomes:
- no action because the event is already resolved by current state;
- an autonomous repair/retry/recovery with verification;
- a concise status update because something materially changed;
- one specific human question because genuine authority is required.

### Tool-use rule

Use StatefulClanker MCP tools as the authoritative interface for task/Intent/control state. Use shell/file tools for project inspection and implementation repair when necessary, but do not hand-edit .statefulclanker bookkeeping files when a StatefulClanker tool exists for that transition.
`;
const OPERATOR_MANUAL = join(INSTALL_ROOT, "skills", "statefulclanker", "SKILL.md");
const PLANNER_SKILL = join(INSTALL_ROOT, "skills", "statefulclanker-planner", "SKILL.md");

function planningIntent(prompt: string): boolean {
  const text = prompt.trim().toLowerCase();
  if (!text) return false;

  const explicit = [
    /\bplanning\b/,
    /^\s*plan\b/,
    /\b(?:build|create|make|write|draft|generate|construct|design|prepare|revise|update|rework|repair|redo)\b.{0,100}\bplan\b/,
    /\bplan\b.{0,100}\b(?:this|it|out|for|implementation|project|feature|work)\b/,
    /\bdecompos(?:e|ing|ition)\b/,
    /\bbreak\s+(?:this|it|work|the\s+work)\s+(?:down|up)\b/,
    /\btask\s+(?:list|graph|breakdown|decomposition)\b/,
    /\bscplan\b/,
    /\bimplementation\s+plan\b/,
    /\bproject\s+plan\b/,
    /\bwork\s+plan\b/,
    /\bmilestones?\b.*\btasks?\b/,
    /\bturn\s+.+\s+into\s+(?:a\s+)?(?:plan|tasks?|task\s+graph)\b/,
    /\bmap\s+out\b.*\b(?:work|tasks?|implementation)\b/,
  ];
  return explicit.some((pattern) => pattern.test(text));
}

function readPlannerSkill(): string {
  try {
    return readFileSync(PLANNER_SKILL, "utf8");
  } catch (error) {
    return [
      "# StatefulClanker planner skill unavailable",
      "",
      `The planner skill could not be read from ${PLANNER_SKILL}.`,
      `Error: ${error instanceof Error ? error.message : String(error)}`,
      "",
      "Do not silently fall back to ad-hoc decomposition. Use the canonical control-plane planning rules and surface the missing planner skill as an installation defect.",
    ].join("\n");
  }
}

function projectRoot(cwd: string): string | null {
  let current = resolve(cwd);
  for (;;) {
    if (existsSync(join(current, ".statefulclanker", "state.json"))) return current;
    const parent = resolve(current, "..");
    if (parent === current) return null;
    current = parent;
  }
}

class StdioMcpClient {
  readonly project: string;
  private child: ChildProcessWithoutNullStreams;
  private nextId = 1;
  private pending = new Map<number, PendingRpc>();
  private stdoutBuffer = "";
  private closed = false;

  constructor(project: string) {
    this.project = project;
    this.child = spawn(
      "powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", MCP_SCRIPT, "-ProjectPath", project],
      {
        cwd: project,
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"],
      },
    );

    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk: string) => this.acceptStdout(chunk));

    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk: string) => {
      const text = chunk.trim();
      if (text) console.error(`[StatefulClanker stdio] ${text}`);
    });

    this.child.on("error", (error) => this.failAll(error));
    this.child.on("close", (code) => {
      this.closed = true;
      this.failAll(new Error(`StatefulClanker stdio MCP exited with code ${code ?? "unknown"}.`));
    });
  }

  get alive(): boolean {
    return !this.closed && this.child.exitCode === null;
  }

  private acceptStdout(chunk: string) {
    this.stdoutBuffer += chunk;
    for (;;) {
      const newline = this.stdoutBuffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.stdoutBuffer.slice(0, newline).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      if (!line) continue;

      let envelope: any;
      try {
        envelope = JSON.parse(line);
      } catch {
        console.error(`[StatefulClanker stdio] Ignoring non-JSON stdout: ${line}`);
        continue;
      }

      const id = Number(envelope?.id);
      const pending = this.pending.get(id);
      if (!pending) continue;
      this.pending.delete(id);

      if (envelope.error) {
        pending.reject(new Error(envelope.error.message ?? JSON.stringify(envelope.error)));
      } else {
        pending.resolve(envelope.result);
      }
    }
  }

  private failAll(error: Error) {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }

  rpc(method: string, params: unknown = {}): Promise<any> {
    if (!this.alive) {
      return Promise.reject(new Error("StatefulClanker stdio MCP is not running."));
    }

    const id = this.nextId++;
    const request = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.child.stdin.write(request + "\n", "utf8", (error) => {
        if (!error) return;
        this.pending.delete(id);
        reject(error);
      });
    });
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    try {
      this.child.stdin.end();
    } catch {
      // Best-effort shutdown. The parent Pi process owns the child lifetime.
    }
    this.failAll(new Error("StatefulClanker stdio MCP closed."));
  }
}

function parseToolPayload(result: any): any {
  const content = Array.isArray(result?.content) ? result.content : [];
  const text = content.find((item: any) => item?.type === "text" && typeof item.text === "string")?.text;
  if (typeof text !== "string") return result;
  try {
    return JSON.parse(text);
  } catch {
    return { text };
  }
}

function buildOperatorBootPacket(project: string): string {
  let manual: string;
  try {
    manual = readFileSync(OPERATOR_MANUAL, "utf8");
  } catch (error) {
    manual = [
      "# Canonical StatefulClanker field manual unavailable",
      "",
      `The canonical operator manual could not be read from ${OPERATOR_MANUAL}.`,
      `Error: ${error instanceof Error ? error.message : String(error)}`,
      "",
      "Use the bundled Pi operating manual above and operate conservatively.",
    ].join("\n");
  }

  return [
    "STATEFULCLANKER BUNDLED PI BOOT PACKET",
    "",
    `Active project: ${project}`,
    "",
    "Read and internalize this packet before handling the first human request or reacting to a control-plane event.",
    "Do not answer this boot packet itself. It is hidden operating context.",
    "",
    PI_OPERATOR_ADDENDUM.trim(),
    "",
    "----- BEGIN CANONICAL STATEFULCLANKER FIELD MANUAL -----",
    manual,
    "----- END CANONICAL STATEFULCLANKER FIELD MANUAL -----",
  ].join("\n");
}

function eventDataRecord(event: ControlEvent): Record<string, any> | null {
  return event.data && typeof event.data === "object" && !Array.isArray(event.data)
    ? (event.data as Record<string, any>)
    : null;
}

function taskIdsForEvent(event: ControlEvent): string[] {
  const ids: string[] = [];
  const data = eventDataRecord(event);
  const direct = data?.taskId;
  if (typeof direct === "string" && direct.trim()) ids.push(direct.trim());

  const stalled = Array.isArray(data?.stalledTasks) ? data!.stalledTasks : [];
  for (const item of stalled) {
    if (!item || typeof item !== "object") continue;
    const id = (item as Record<string, any>).id ?? (item as Record<string, any>).taskId;
    if (typeof id === "string" && id.trim()) ids.push(id.trim());
  }

  return [...new Set(ids)].slice(0, 8);
}

async function readCurrentTask(client: StdioMcpClient, taskId: string): Promise<any | null> {
  try {
    const result = await client.rpc("tools/call", {
      name: "task_show",
      arguments: { taskId },
    });
    return parseToolPayload(result);
  } catch {
    return null;
  }
}

async function readCurrentAutofill(client: StdioMcpClient): Promise<any | null> {
  try {
    const result = await client.rpc("tools/call", {
      name: "autofill_status",
      arguments: {},
    });
    return parseToolPayload(result);
  } catch {
    return null;
  }
}

async function readCurrentTaskList(client: StdioMcpClient): Promise<any[]> {
  try {
    const result = await client.rpc("tools/call", {
      name: "task_list",
      arguments: {},
    });
    const payload = parseToolPayload(result);
    return Array.isArray(payload) ? payload : Array.isArray(payload?.tasks) ? payload.tasks : [];
  } catch {
    return [];
  }
}


async function readControlSnapshot(client: StdioMcpClient): Promise<any | null> {
  try {
    const result = await client.rpc("tools/call", {
      name: "control_snapshot",
      arguments: {},
    });
    return parseToolPayload(result);
  } catch {
    return null;
  }
}

function boundedText(value: unknown, maxChars: number): string {
  const text = typeof value === "string" ? value : String(value ?? "");
  if (text.length <= maxChars) return text;
  const head = Math.floor(maxChars * 0.68);
  const tail = Math.max(0, maxChars - head - 96);
  return text.slice(0, head) + "\n... [middle omitted by StatefulClanker reality compaction] ...\n" + text.slice(-tail);
}

const COMPACT_TOOL_RESULTS = new Set([
  "task_recovery_context",
  "control_snapshot",
  "task_list",
  "task_show",
  "autofill_status",
  "connection_catalog",
  "target_pool_list",
]);

function isModelScalar(value: unknown): boolean {
  return value === null || value === undefined || ["string", "number", "boolean", "bigint"].includes(typeof value);
}

function compactScalar(value: unknown): string {
  if (value === null || value === undefined) return "~";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") {
    if (value.length === 0) return '""';
    return value.replace(/\\/g, "\\\\").replace(/\|/g, "\\|").replace(/\r/g, "").replace(/\n/g, "\\n");
  }
  return String(value);
}

function compactObjectEntries(value: unknown): Array<[string, unknown]> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return [];
  return Object.entries(value as Record<string, unknown>);
}

function canCompactTable(items: unknown[]): boolean {
  if (items.length < 2) return false;
  const first = compactObjectEntries(items[0]);
  if (first.length === 0 || first.length > 16 || first.some(([, value]) => !isModelScalar(value))) return false;
  const names = first.map(([name]) => name);
  for (const item of items.slice(1)) {
    const entries = compactObjectEntries(item);
    if (entries.length !== names.length) return false;
    for (let i = 0; i < names.length; i++) {
      if (entries[i][0] !== names[i] || !isModelScalar(entries[i][1])) return false;
    }
  }
  return true;
}

function compactModelLines(value: unknown, depth = 12, indent = 0): string[] {
  const pad = " ".repeat(Math.max(0, indent));
  if (depth <= 0) return [pad + "..."];
  if (isModelScalar(value)) return [pad + compactScalar(value)];

  if (Array.isArray(value)) {
    if (value.length === 0) return [pad + "[]"];
    if (value.every(isModelScalar)) return [pad + "[" + value.map(compactScalar).join(" | ") + "]"];
    if (canCompactTable(value)) {
      const names = compactObjectEntries(value[0]).map(([name]) => name);
      return [
        pad + "[" + names.join("|") + "]",
        ...value.map((item) => pad + compactObjectEntries(item).map(([, v]) => compactScalar(v)).join("|")),
      ];
    }
    const lines: string[] = [];
    for (const item of value) {
      if (isModelScalar(item)) {
        lines.push(pad + "- " + compactScalar(item));
      } else {
        lines.push(pad + "-");
        lines.push(...compactModelLines(item, depth - 1, indent + 2));
      }
    }
    return lines;
  }

  const entries = compactObjectEntries(value);
  if (entries.length === 0) return [pad + compactScalar(String(value))];
  const lines: string[] = [];
  for (const [name, item] of entries) {
    if (isModelScalar(item)) {
      if (typeof item === "string" && item.includes("\n")) {
        lines.push(pad + name + ":");
        for (const line of item.split(/\r?\n/)) lines.push(" ".repeat(indent + 2) + line);
      } else {
        lines.push(pad + name + "=" + compactScalar(item));
      }
    } else {
      lines.push(pad + name + ":");
      lines.push(...compactModelLines(item, depth - 1, indent + 2));
    }
  }
  return lines;
}

function compactModelText(value: unknown, maxChars = 0, depth = 12): string {
  let text = compactModelLines(value, depth, 0).join("\n");
  if (maxChars > 0) text = boundedText(text, maxChars);
  return text;
}

function compactToolContent(toolName: string, content: any[]): any[] {
  if (!COMPACT_TOOL_RESULTS.has(toolName)) return content;
  return content.map((item: any) => {
    if (item?.type !== "text" || typeof item.text !== "string") return item;
    try {
      const parsed = JSON.parse(item.text);
      return {
        ...item,
        text: "STATEFULCLANKER COMPACT PROJECTION\n" + compactModelText(parsed, 48_000, 18),
      };
    } catch {
      return item;
    }
  });
}

function stringList(value: unknown): string[] {
  if (!value) return [];
  if (Array.isArray(value)) {
    return value.filter((item): item is string => typeof item === "string");
  }
  if (value instanceof Set) {
    return [...value].filter((item): item is string => typeof item === "string");
  }
  if (typeof (value as any)?.[Symbol.iterator] === "function" && typeof value !== "string") {
    try {
      return [...(value as Iterable<unknown>)].filter((item): item is string => typeof item === "string");
    } catch {
      return [];
    }
  }
  return [];
}

function runGit(project: string, args: string[], maxChars = 12_000): string {
  try {
    const output = execFileSync("git", ["-C", project, ...args], {
      encoding: "utf8",
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 4 * 1024 * 1024,
    });
    return boundedText(output.trim(), maxChars);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return "[git unavailable: " + boundedText(message, 600) + "]";
  }
}

function gitPathLines(project: string, args: string[]): string[] {
  const output = runGit(project, args, 24_000);
  if (!output || output.startsWith("[git unavailable:")) return [];
  return output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function currentGitReality(project: string) {
  const changedFiles = [
    ...gitPathLines(project, ["diff", "--name-only"]),
    ...gitPathLines(project, ["diff", "--cached", "--name-only"]),
    ...gitPathLines(project, ["ls-files", "--others", "--exclude-standard"]),
  ];
  return {
    branch: runGit(project, ["rev-parse", "--abbrev-ref", "HEAD"], 500),
    head: runGit(project, ["rev-parse", "--short=12", "HEAD"], 500),
    status: runGit(project, ["status", "--short", "--branch"], 12_000),
    diffStat: runGit(project, ["diff", "--stat"], 8_000),
    cachedDiffStat: runGit(project, ["diff", "--cached", "--stat"], 8_000),
    diff: [
      runGit(project, ["diff", "--no-ext-diff", "--unified=2"], Math.floor(REALITY_DIFF_MAX_CHARS * 0.65)),
      runGit(project, ["diff", "--cached", "--no-ext-diff", "--unified=2"], Math.floor(REALITY_DIFF_MAX_CHARS * 0.35)),
    ]
      .filter(Boolean)
      .join("\n\n"),
    recentCommits: runGit(project, ["log", "-6", "--oneline", "--decorate"], 5_000),
    changedFiles: [...new Set(changedFiles)].slice(0, 24),
  };
}

function taskPriority(task: any): number {
  const status = String(task?.status ?? "").toLowerCase();
  const order: Record<string, number> = {
    running: 0,
    reviewing: 1,
    validating: 2,
    needs_rework: 3,
    stale: 4,
    failed: 5,
    blocked: 6,
    ready: 7,
    pending: 8,
    complete: 20,
  };
  return order[status] ?? 12;
}

function selectRealityTasks(tasks: any[]): any[] {
  return [...tasks]
    .sort((a, b) => taskPriority(a) - taskPriority(b))
    .slice(0, 10);
}

function retrievalPath(value: string): string {
  return value.replace(/^file:/i, "").replace(/#L\d+(?:-L?\d+)?$/i, "").trim();
}

function safeProjectFile(project: string, requestedPath: string): { path: string; content: string } | null {
  const cleaned = retrievalPath(requestedPath);
  if (!cleaned || cleaned.startsWith(".statefulclanker") || cleaned.startsWith(".git")) return null;

  const candidate = resolve(project, cleaned);
  const rel = relative(project, candidate);
  if (!rel || rel.startsWith("..") || isAbsolute(rel)) return null;

  try {
    const raw = readFileSync(candidate);
    if (raw.includes(0)) return null;
    return {
      path: rel,
      content: boundedText(raw.toString("utf8"), REALITY_FILE_MAX_CHARS),
    };
  } catch {
    return null;
  }
}

function messageText(message: any): string {
  const content = message?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((item: any) => item?.type === "text" && typeof item.text === "string")
    .map((item: any) => item.text)
    .join("\n");
}

async function buildRealityCompaction(
  client: StdioMcpClient,
  project: string,
  preparation: any,
  reason: string,
  customInstructions?: string,
  contextWindow?: number,
): Promise<{ summary: string; details: Record<string, unknown> }> {
  const [taskList, autofill, controlSnapshot] = await Promise.all([
    readCurrentTaskList(client),
    readCurrentAutofill(client),
    readControlSnapshot(client),
  ]);

  const selected = selectRealityTasks(taskList);
  const currentTasks: any[] = [];
  for (const task of selected) {
    const id = typeof task?.id === "string" ? task.id : "";
    if (!id) {
      currentTasks.push(task);
      continue;
    }
    currentTasks.push((await readCurrentTask(client, id)) ?? task);
  }

  const git = currentGitReality(project);
  const fileCandidates: string[] = [...git.changedFiles];
  for (const task of currentTasks) {
    for (const item of Array.isArray(task?.retrieval) ? task.retrieval : []) {
      if (typeof item === "string") fileCandidates.push(item);
    }
  }

  const fileSnapshots: Array<{ path: string; content: string }> = [];
  const seen = new Set<string>();
  for (const candidate of fileCandidates) {
    const snapshot = safeProjectFile(project, candidate);
    if (!snapshot) continue;
    const key = snapshot.path.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    fileSnapshots.push(snapshot);
    if (fileSnapshots.length >= REALITY_FILE_COUNT) break;
  }

  const statusCounts = new Map<string, number>();
  for (const task of taskList) {
    const status = String(task?.status ?? "unknown");
    statusCounts.set(status, (statusCounts.get(status) ?? 0) + 1);
  }

  const discardedUserEvidence = (Array.isArray(preparation?.messagesToSummarize)
    ? preparation.messagesToSummarize
    : [])
    .filter((message: any) => message?.role === "user")
    .map(messageText)
    .filter(Boolean)
    .slice(-8)
    .map((text: string) => boundedText(text, 1_400));

  const sections: string[] = [
    "# STATEFULCLANKER REALITY CHECKPOINT",
    [
      "Generated mechanically at Pi compaction time; no summarization-model request was used.",
      "Project: " + project,
      "Compaction trigger: " + reason,
      "Authority/order of trust: current repository + deterministic evidence > current durable Clanker state > current Human Directives/Intent > recent raw conversation > historical carryover.",
      "Treat old plans, worker claims, reviewer claims, and the archival section below as evidence only. If they conflict with current reality, current reality wins.",
    ].join("\n"),
    "## CURRENT REPOSITORY STATE\n" +
      compactModelText(
        {
          branch: git.branch,
          head: git.head,
          status: git.status,
          diffStat: git.diffStat,
          cachedDiffStat: git.cachedDiffStat,
          changedFiles: git.changedFiles,
        },
        18_000,
      ),
    "## CURRENT CONTROL / HUMAN-AUTHORITY STATE\n" +
      (controlSnapshot ? compactModelText(controlSnapshot, 18_000) : "control_snapshot unavailable at compaction time"),
    "## CURRENT AUTOFILL STATE\n" +
      (autofill ? compactModelText(autofill, 8_000) : "autofill_status unavailable at compaction time"),
    "## CURRENT TASK GRAPH\nTask counts: " +
      [...statusCounts.entries()]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([status, count]) => status + "=" + count)
        .join(", ") +
      "\n\nHighest-priority current task objects:\n" +
      compactModelText(currentTasks, 26_000),
  ];

  if (fileSnapshots.length > 0) {
    sections.push(
      "## CURRENT FILE SNAPSHOTS\n" +
        fileSnapshots
          .map((file) => "### " + file.path + "\n~~~\n" + file.content + "\n~~~")
          .join("\n\n"),
    );
  }

  if (git.diff && !git.diff.startsWith("[git unavailable:")) {
    sections.push("## CURRENT WORKTREE DIFF\n~~~diff\n" + boundedText(git.diff, REALITY_DIFF_MAX_CHARS) + "\n~~~");
  }

  sections.push("## RECENT COMMIT ANCHORS\n" + git.recentCommits);

  if (discardedUserEvidence.length > 0) {
    sections.push(
      "## USER EVIDENCE FROM THE DISCARDED HISTORY\n" +
        "These are user message extracts, not a generated interpretation. Reconcile them against current Human Directives/Intent before treating them as active authority.\n\n" +
        discardedUserEvidence.map((text: string, index: number) => "### User evidence " + (index + 1) + "\n" + text).join("\n\n"),
    );
  }

  if (customInstructions?.trim()) {
    sections.push(
      "## MANUAL COMPACTION NOTE\n" +
        boundedText(customInstructions.trim(), 2_000),
    );
  }

  if (preparation?.previousSummary) {
    sections.push(
      "## ARCHIVAL CARRYOVER — LOW AUTHORITY, VERIFY BEFORE USE\n" +
        "This is a small fragment of the prior compaction only to prevent accidental loss of older context that may not yet be durable. It may be stale.\n\n" +
        boundedText(preparation.previousSummary, REALITY_HISTORY_MAX_CHARS),
    );
  }

  let summary = sections.join("\n\n");
  const contextScaledBudget =
    contextWindow && contextWindow > 0
      ? Math.max(24_000, Math.floor(contextWindow * 1.5))
      : REALITY_PACKET_MAX_CHARS;
  summary = boundedText(summary, Math.min(REALITY_PACKET_MAX_CHARS, contextScaledBudget));

  const fileOps = preparation?.fileOps ?? {};
  const details = {
    strategy: REALITY_COMPACTION_STRATEGY,
    generatedAt: new Date().toISOString(),
    project,
    reason,
    readFiles: stringList(fileOps.read),
    modifiedFiles: stringList(fileOps.edited ?? fileOps.modified),
    realityFiles: fileSnapshots.map((file) => file.path),
    taskIds: currentTasks.map((task) => task?.id).filter((id): id is string => typeof id === "string"),
  };

  return { summary, details };
}

function isProblemEvent(event: ControlEvent): boolean {
  return /(stagnation|failed|failure|error|crash|abandoned|blocked|invalidated|stale|conflict|fault|retry|rejected|warning|plan_repair|required|failover_stopped)/i.test(
    event.type ?? "",
  );
}

function investigationStart(event: ControlEvent, taskIds: string[]): string {
  const type = event.type ?? "event";
  if (type === "autofill.stalled") {
    return "START HERE: autofill_status() -> task_list() -> for each task that is CURRENTLY terminal-stalled, task_show(taskId) -> task_recovery_context(taskId) -> inspect the concrete project files/tests before changing task state.";
  }
  if (taskIds.length > 0) {
    const id = taskIds[0];
    return `START HERE: task_show({taskId:"${id}"}) -> if the task is not complete and the event still describes current reality, task_recovery_context({taskId:"${id}"}) -> inspect concrete files/tests -> repair the least-authoritative layer that is actually wrong.`;
  }
  if (/directive|intent|human\.required/.test(type)) {
    return "START HERE: control_snapshot() -> inspect current Human Directives and reconciled Intent. Confirm the authority conflict still exists before asking the human.";
  }
  if (/project\.hold|project\.review/.test(type)) {
    return "START HERE: control_snapshot() -> inspect the CURRENT project hold and review evidence -> verify the cited defect against current repository/tests before treating the hold as valid.";
  }
  if (/routing|provider|endpoint/.test(type)) {
    return "START HERE: autofill_status() and current routing/endpoint health. Determine whether work is still routing-deferred now; do not escalate a cooldown that has already cleared.";
  }
  return "START HERE: control_snapshot() -> identify the current durable object implicated by this event -> inspect that object's current state and concrete evidence before mutating anything.";
}

async function formatControlMessage(client: StdioMcpClient, events: ControlEvent[]): Promise<string | null> {
  const taskList = await readCurrentTaskList(client);
  const taskById = new Map<string, any>();
  const counts = new Map<string, number>();
  for (const task of taskList) {
    if (typeof task?.id === "string") taskById.set(task.id, task);
    const status = String(task?.status ?? "unknown");
    counts.set(status, (counts.get(status) ?? 0) + 1);
  }

  const taskSummary =
    taskList.length > 0
      ? [...counts.entries()]
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([status, count]) => `${status}=${count}`)
          .join(", ")
      : "task_list unavailable";

  const lines: string[] = [];
  let retainedEvents = 0;

  for (const event of events) {
    const level = event.level ?? "fyi";
    const type = event.type ?? "event";
    const message = event.message ? `: ${event.message}` : "";
    const taskIds = taskIdsForEvent(event);

    const currentTasks: Array<{ id: string; task: any | null }> = [];
    for (const id of taskIds) {
      let task = taskById.get(id) ?? null;
      if (!task) {
        task = await readCurrentTask(client, id);
        if (task) taskById.set(id, task);
      }
      currentTasks.push({ id, task });
    }

    // A delayed problem event about work that is now complete is historical,
    // not a reason to wake Pi and reopen the task.
    if (
      isProblemEvent(event) &&
      currentTasks.length > 0 &&
      currentTasks.every(({ task }) => task && String(task.status).toLowerCase() === "complete")
    ) {
      continue;
    }

    let autofill: any | null = null;
    if (type === "autofill.stalled") {
      autofill = await readCurrentAutofill(client);
      const state = String(autofill?.state ?? "").toLowerCase();
      if (state && state !== "blocked") {
        // The supervisor has already advanced out of the stalled state.
        continue;
      }
    }

    retainedEvents += 1;
    lines.push(`- [${level}] ${type}${message}`);

    if (currentTasks.length > 0) {
      lines.push("  CURRENT TASK OBJECTS:");
      for (const { id, task } of currentTasks) {
        if (!task) {
          lines.push(`  - ${id}: current task object unavailable; verify with task_show before acting.`);
          continue;
        }
        const status = String(task.status ?? "unknown");
        const attempts = Number(task.attemptCount ?? 0);
        const rejects = Number(task.validatorRejectCount ?? 0);
        const reason = task.blockReason ? `; blockReason=${String(task.blockReason).slice(0, 500)}` : "";
        lines.push(`  - ${id}: CURRENT status=${status}; attempts=${attempts}; validatorRejects=${rejects}${reason}`);

        const retrieval = Array.isArray(task.retrieval)
          ? task.retrieval.filter((item: unknown) => typeof item === "string").slice(0, 6)
          : [];
        if (retrieval.length > 0) {
          lines.push(`    inspect-first paths: ${retrieval.join(", ")}`);
        }

        const acceptance = Array.isArray(task.acceptance)
          ? task.acceptance.filter((item: unknown) => typeof item === "string").slice(0, 4)
          : [];
        if (acceptance.length > 0) {
          lines.push(`    acceptance to verify: ${acceptance.map((item: string) => item.slice(0, 220)).join(" | ")}`);
        }

        const pointers = [
          task.latestRunId ? `run=${task.latestRunId}` : null,
          task.latestValidationId ? `validation=${task.latestValidationId}` : null,
          task.latestProposalId ? `proposal=${task.latestProposalId}` : null,
          task.latestCompilationId ? `compilation=${task.latestCompilationId}` : null,
        ].filter(Boolean);
        if (pointers.length > 0) {
          lines.push(`    latest evidence: ${pointers.join("; ")}`);
        }
      }
    }

    if (autofill) {
      const state = String(autofill.state ?? "unknown");
      const ready = Number(autofill.readyCount ?? 0);
      const active = Array.isArray(autofill.activeTasks)
        ? autofill.activeTasks.length
        : Number(autofill.activeWorkers ?? autofill.ownedActive ?? 0);
      const block = autofill.blockReason ? `; blockReason=${String(autofill.blockReason).slice(0, 500)}` : "";
      lines.push(`  CURRENT AUTOFILL: state=${state}; active=${active}; ready=${ready}${block}`);
    }

    lines.push(`  ${investigationStart(event, taskIds)}`);
  }

  if (retainedEvents === 0) return null;

  return [
    "STATEFULCLANKER CONTROL-PLANE EVENT",
    "",
    "This packet contains EVENT-TIME evidence plus CURRENT durable state sampled immediately before injection. Reconcile them. Current task/project/repository reality wins over stale event chronology.",
    `CURRENT TASK_LIST SNAPSHOT: ${taskSummary}`,
    "",
    ...lines,
    "",
    "CONTROL-PLANE DUTY: keep task_list and each task object synchronized with the actual project. If code/tests/artifacts and task bookkeeping disagree, investigate which layer is stale or wrong and repair that layer rather than blindly doing the task again.",
    "Treat attention events as work to investigate and repair autonomously using the StatefulClanker tools.",
    "A stagnation/recovery event is not proof that the named task still needs work. Completed tasks must not be reopened merely because an older warning arrives.",
    "For human_required events, verify that the authority gap still exists now, then ask only the smallest genuinely unresolved human/Intent question.",
  ].join("\n");
}

export default async function statefulClankerExtension(pi: ExtensionAPI) {
  let client: StdioMcpClient | null = null;
  let root: string | null = null;
  let cursor = 0;
  let timer: ReturnType<typeof setInterval> | null = null;
  let delivering = false;
  let manualQueuedForRoot: string | null = null;
  let compactionInFlight = false;
  let turnsSinceCompaction = Number.MAX_SAFE_INTEGER;

  const ensureClient = (cwd: string): StdioMcpClient => {
    const nextRoot = projectRoot(cwd) ?? resolve(cwd);
    if (client?.alive && root === nextRoot) return client;

    client?.close();
    root = nextRoot;
    cursor = 0;
    client = new StdioMcpClient(nextRoot);
    return client;
  };

  const queueOperatorManual = (project: string) => {
    if (manualQueuedForRoot === project) return;
    const content = buildOperatorBootPacket(project);
    pi.sendMessage(
      {
        customType: OPERATOR_MANUAL_MESSAGE_TYPE,
        content,
        display: false,
        details: {
          project,
          source: OPERATOR_MANUAL,
          purpose: "StatefulClanker control-plane boot manual",
        },
      },
      {
        triggerTurn: false,
        deliverAs: "nextTurn",
      },
    );
    manualQueuedForRoot = project;
  };

  const controlEventsSince = async (since: number): Promise<{ cursor: number; events: ControlEvent[] }> => {
    if (!client) return { cursor: since, events: [] };
    const result = await client.rpc("tools/call", {
      name: "control_events_since",
      arguments: { since, limit: 250, minimumLevel: "attention" },
    });
    const payload = parseToolPayload(result);
    return {
      cursor: Number(payload?.cursor ?? since) || since,
      events: Array.isArray(payload?.events) ? payload.events : [],
    };
  };

  const establishCursorAtLiveEdge = async () => {
    if (!client) return;
    try {
      const current = await controlEventsSince(0);
      cursor = current.cursor;
    } catch (error) {
      console.error(
        `[StatefulClanker extension] control cursor unavailable: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  };

  const poll = async () => {
    if (!client?.alive || delivering) return;
    const activeClient = client;

    try {
      const next = await controlEventsSince(cursor);
      cursor = Math.max(cursor, next.cursor, ...next.events.map((event) => Number(event.sequence) || 0));
      const actionable = next.events.filter(
        (event) => event.level === "attention" || event.level === "human_required",
      );
      if (actionable.length === 0) return;

      const content = await formatControlMessage(activeClient, actionable);
      if (!content) return;

      delivering = true;
      await Promise.resolve(
        pi.sendMessage(
          {
            customType: CONTROL_MESSAGE_TYPE,
            content,
            display: false,
            details: {
              firstSequence: actionable[0]?.sequence,
              lastSequence: actionable.at(-1)?.sequence,
            },
          },
          {
            triggerTurn: true,
            deliverAs: "followUp",
          },
        ),
      );
    } catch (error) {
      console.error(
        `[StatefulClanker extension] control-event delivery failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    } finally {
      delivering = false;
    }
  };

  // Register the StatefulClanker MCP surface as native Pi tools. The stdio child is
  // explicitly pinned to the project Pi was launched inside, so tool calls do not
  // depend on tray state, loopback networking, bearer tokens, or resident-host discovery.
  try {
    const initial = ensureClient(process.cwd());
    const listed = await initial.rpc("tools/list", {});
    for (const tool of (listed?.tools ?? []) as McpTool[]) {
      if (!tool?.name) continue;
      const schema =
        tool.inputSchema && typeof tool.inputSchema === "object"
          ? tool.inputSchema
          : { type: "object", properties: {} };

      pi.registerTool({
        name: tool.name,
        label: `Clanker: ${tool.name}`,
        description: tool.description ?? `Call StatefulClanker MCP tool ${tool.name}.`,
        parameters: schema as any,
        promptSnippet: `StatefulClanker control-plane tool: ${tool.name}`,
        async execute(_toolCallId, params) {
          try {
            const active = ensureClient(root ?? process.cwd());
            const result = await active.rpc("tools/call", {
              name: tool.name,
              arguments: params ?? {},
            });
            const content = Array.isArray(result?.content) ? result.content : [];
            if (content.length > 0) {
              const projected = compactToolContent(tool.name, content);
              return {
                content: projected,
                details: {
                  source: "statefulclanker-stdio",
                  tool: tool.name,
                  projection: COMPACT_TOOL_RESULTS.has(tool.name) ? "compact-model-text" : "canonical",
                },
              };
            }
            return {
              content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }],
              details: { source: "statefulclanker-stdio", tool: tool.name },
            };
          } catch (error) {
            return {
              content: [
                {
                  type: "text",
                  text: `StatefulClanker tool failed: ${error instanceof Error ? error.message : String(error)}`,
                },
              ],
              details: { source: "statefulclanker-stdio", tool: tool.name },
              isError: true,
            };
          }
        },
      });
    }
  } catch (error) {
    console.error(
      `[StatefulClanker extension] MCP tool discovery unavailable: ${error instanceof Error ? error.message : String(error)}`,
    );
  }

  pi.on("session_before_compact", async (event, ctx) => {
    compactionInFlight = true;
    try {
      const active = ensureClient(ctx.cwd);
      const project = root ?? projectRoot(ctx.cwd) ?? resolve(ctx.cwd);
      const rebuilt = await buildRealityCompaction(
        active,
        project,
        event.preparation,
        event.reason ?? "unknown",
        event.customInstructions,
        ctx.getContextUsage()?.contextWindow,
      );

      return {
        compaction: {
          summary: rebuilt.summary,
          firstKeptEntryId: event.preparation.firstKeptEntryId,
          tokensBefore: event.preparation.tokensBefore,
          details: rebuilt.details,
        },
      };
    } catch (error) {
      console.error(
        "[StatefulClanker extension] reality compaction failed; falling back to Pi default compaction: " +
          (error instanceof Error ? error.message : String(error)),
      );
      return;
    }
  });

  pi.on("session_compact", () => {
    compactionInFlight = false;
    turnsSinceCompaction = 0;
  });

  pi.on("session_compact_failed", () => {
    compactionInFlight = false;
  });

  pi.on("turn_end", (_event, ctx) => {
    turnsSinceCompaction += 1;
    if (compactionInFlight || turnsSinceCompaction < REALITY_COMPACTION_MIN_TURNS) return;

    const usage = ctx.getContextUsage();
    const tokens = usage?.tokens ?? null;
    const contextWindow = usage?.contextWindow ?? 0;
    if (tokens === null || contextWindow <= 0) return;

    const triggerTokens = Math.max(
      REALITY_COMPACTION_MIN_TRIGGER_TOKENS,
      Math.min(
        REALITY_COMPACTION_MAX_TRIGGER_TOKENS,
        Math.floor(contextWindow * REALITY_COMPACTION_TRIGGER_FRACTION),
      ),
    );
    if (tokens < triggerTokens) return;

    compactionInFlight = true;
    ctx.compact({
      customInstructions:
        "Routine StatefulClanker reality refresh. Reconstitute from current project state; do not preserve stale conversational bulk merely for continuity.",
      onComplete: () => {
        compactionInFlight = false;
        turnsSinceCompaction = 0;
      },
      onError: (error) => {
        compactionInFlight = false;
        console.error(
          "[StatefulClanker extension] proactive reality compaction failed: " +
            (error instanceof Error ? error.message : String(error)),
        );
      },
    });
  });

  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.sections.statefulclanker = [
      "## StatefulClanker control plane",
      "This Pi instance is the human-facing control plane for the active StatefulClanker project.",
      "A full StatefulClanker operator field manual is injected as hidden session context at startup. Treat that manual as operating guidance, not optional background reading.",
      "Use the registered StatefulClanker tools for durable intent, directives, plan/task state, recovery, routing, telemetry, and autofill control.",
      "Current Human Directives and reconciled Intent outrank plan/task text; plan/task text outranks worker/reviewer claims.",
      "Control events are wake-up/history signals, not proof of current truth. Re-check canonical task state and concrete artifacts before acting on stagnation/recovery warnings.",
      "Never reopen or redo a task that is already canonically complete merely because an older stagnation warning arrives.",
      "Mechanical stalls and repeated validator/reviewer failures are recovery requests first: investigate and repair the actual broken layer before escalating to the human.",
      "Pi compaction is reality-first: old conversational bulk is replaced with a mechanically rebuilt checkpoint from current git/project/task state while Pi retains its normal recent raw tail. Treat archival carryover as low-authority evidence.",
      "Reality compaction is intentionally proactive and frequent: the bundled Pi refreshes its working context well before the provider context window is close to full.",
    ].join("\n");

    if (planningIntent(event.prompt)) {
      event.systemPromptOptions.sections.statefulclankerPlanner = [
        "## MANDATORY STATEFULCLANKER PLANNING MODE",
        "The current human turn requests planning, plan construction/revision, decomposition, a task list/task graph, or SCPLAN.",
        "Apply the following planner skill in full before creating or materially revising the plan.",
        "Do not substitute ad-hoc decomposition for this methodology.",
        "",
        readPlannerSkill(),
      ].join("\n");
    } else {
      delete event.systemPromptOptions.sections.statefulclankerPlanner;
    }
  });

  pi.on("session_start", async (_event, ctx) => {
    ensureClient(ctx.cwd);
    if (root) queueOperatorManual(root);
    await establishCursorAtLiveEdge();
    if (!timer) timer = setInterval(() => void poll(), CONTROL_POLL_MS);
  });

  pi.on("agent_settled", (_event, ctx) => {
    const previous = root;
    ensureClient(ctx.cwd);
    if (root !== previous) {
      if (root) queueOperatorManual(root);
      void establishCursorAtLiveEdge();
      return;
    }
    void poll();
  });

  process.once("exit", () => client?.close());
}
