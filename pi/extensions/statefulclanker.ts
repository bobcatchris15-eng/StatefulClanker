import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
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
const INSTALL_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MCP_SCRIPT = join(INSTALL_ROOT, "mcp", "StatefulClanker.Mcp.ps1");

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

function formatControlMessage(events: ControlEvent[]): string {
  const lines = events.map((event) => {
    const level = event.level ?? "fyi";
    const type = event.type ?? "event";
    const message = event.message ? `: ${event.message}` : "";
    return `- [${level}] ${type}${message}`;
  });

  return [
    "STATEFULCLANKER CONTROL-PLANE EVENT",
    "",
    ...lines,
    "",
    "Treat attention events as work to investigate and repair autonomously using the StatefulClanker tools.",
    "For human_required events, investigate first and ask the human only for the smallest genuinely unresolved authority/intent decision.",
    "Do not merely narrate a recoverable failure. Inspect current state, evidence, task recovery context, and project artifacts, then act.",
  ].join("\n");
}

export default async function statefulClankerExtension(pi: ExtensionAPI) {
  let client: StdioMcpClient | null = null;
  let root: string | null = null;
  let cursor = 0;
  let timer: ReturnType<typeof setInterval> | null = null;
  let delivering = false;

  const ensureClient = (cwd: string): StdioMcpClient => {
    const nextRoot = projectRoot(cwd) ?? resolve(cwd);
    if (client?.alive && root === nextRoot) return client;

    client?.close();
    root = nextRoot;
    cursor = 0;
    client = new StdioMcpClient(nextRoot);
    return client;
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

    try {
      const next = await controlEventsSince(cursor);
      cursor = Math.max(cursor, next.cursor, ...next.events.map((event) => Number(event.sequence) || 0));
      const actionable = next.events.filter(
        (event) => event.level === "attention" || event.level === "human_required",
      );
      if (actionable.length === 0) return;

      delivering = true;
      await Promise.resolve(
        pi.sendMessage(
          {
            customType: CONTROL_MESSAGE_TYPE,
            content: formatControlMessage(actionable),
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
              return {
                content,
                details: { source: "statefulclanker-stdio", tool: tool.name },
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

  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.sections.statefulclanker = [
      "## StatefulClanker control plane",
      "This Pi instance is bundled with StatefulClanker and runs inside the active project.",
      "Use the registered StatefulClanker tools for durable intent, directives, plan/task state, recovery, routing, telemetry, and autofill control.",
      "The project's Human Directives and reconciled Intent are authoritative over inferred implementation preferences.",
      "Mechanical stalls and repeated validator/reviewer failures are recovery requests first: investigate and repair before escalating to the human.",
    ].join("\n");
  });

  pi.on("session_start", async (_event, ctx) => {
    ensureClient(ctx.cwd);
    await establishCursorAtLiveEdge();
    if (!timer) timer = setInterval(() => void poll(), CONTROL_POLL_MS);
  });

  pi.on("agent_settled", (_event, ctx) => {
    const previous = root;
    ensureClient(ctx.cwd);
    if (root !== previous) {
      void establishCursorAtLiveEdge();
      return;
    }
    void poll();
  });

  process.once("exit", () => client?.close());
}
