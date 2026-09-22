import { readFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type McpDetails = { url: string; token?: string; project?: string };
type McpTool = { name: string; description?: string; inputSchema?: Record<string, unknown> };
type ControlEvent = {
  sequence: number;
  level?: "fyi" | "attention" | "human_required";
  type?: string;
  message?: string;
  data?: unknown;
};

const CONTROL_POLL_MS = 1000;
const CONTROL_MESSAGE_TYPE = "statefulclanker-control";

function machineRoot(): string | null {
  const local = process.env.LOCALAPPDATA;
  return local ? join(local, "StatefulClanker") : null;
}

function detailsPath(): string | null {
  const root = machineRoot();
  return root ? join(root, "mcp-http.json") : null;
}

function readDetails(): McpDetails | null {
  const path = detailsPath();
  if (!path || !existsSync(path)) return null;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    if (!parsed?.url) return null;
    return parsed as McpDetails;
  } catch {
    return null;
  }
}

let rpcId = 1;
async function rpc(method: string, params: unknown = {}): Promise<any> {
  const details = readDetails();
  if (!details) throw new Error("StatefulClanker resident MCP endpoint is not available.");

  const headers: Record<string, string> = { "content-type": "application/json" };
  if (details.token) headers.authorization = `Bearer ${details.token}`;

  const response = await fetch(details.url, {
    method: "POST",
    headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: rpcId++, method, params }),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`StatefulClanker MCP HTTP ${response.status}: ${text}`);
  if (!text.trim()) return null;

  const envelope = JSON.parse(text);
  if (envelope.error) throw new Error(envelope.error.message ?? JSON.stringify(envelope.error));
  return envelope.result;
}

function projectRoot(cwd: string): string | null {
  let current = cwd;
  for (;;) {
    if (existsSync(join(current, ".statefulclanker", "state.json"))) return current;
    const parent = join(current, "..");
    const resolvedParent = resolve(parent);
    const resolvedCurrent = resolve(current);
    if (resolvedParent === resolvedCurrent) return null;
    current = resolvedParent;
  }
}

function readLastSequence(root: string): number {
  const path = join(root, ".statefulclanker", "control", "state.json");
  if (!existsSync(path)) return 0;
  try {
    const state = JSON.parse(readFileSync(path, "utf8"));
    return Number(state?.lastSequence ?? 0) || 0;
  } catch {
    return 0;
  }
}

function readControlEvents(root: string, since: number): ControlEvent[] {
  const path = join(root, ".statefulclanker", "control", "events.jsonl");
  if (!existsSync(path)) return [];
  const out: ControlEvent[] = [];
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line) as ControlEvent;
      if (Number(event.sequence) > since) out.push(event);
    } catch {
      // Ignore a partially-written/corrupt line; the next poll will retry newer data.
    }
  }
  return out.sort((a, b) => Number(a.sequence) - Number(b.sequence));
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
  // Give Pi the resident StatefulClanker MCP surface as native LLM-callable tools.
  try {
    const listed = await rpc("tools/list", {});
    for (const tool of (listed?.tools ?? []) as McpTool[]) {
      if (!tool?.name) continue;
      const schema = tool.inputSchema && typeof tool.inputSchema === "object"
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
            const result = await rpc("tools/call", { name: tool.name, arguments: params ?? {} });
            const content = Array.isArray(result?.content) ? result.content : [];
            if (content.length > 0) {
              return { content, details: { source: "statefulclanker-mcp", tool: tool.name } };
            }
            return {
              content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }],
              details: { source: "statefulclanker-mcp", tool: tool.name },
            };
          } catch (error) {
            return {
              content: [{ type: "text", text: `StatefulClanker tool failed: ${error instanceof Error ? error.message : String(error)}` }],
              details: { source: "statefulclanker-mcp", tool: tool.name },
              isError: true,
            };
          }
        },
      });
    }
  } catch (error) {
    // Pi remains usable if the tray/MCP resident is temporarily unavailable.
    console.error(`[StatefulClanker extension] MCP tool discovery unavailable: ${error instanceof Error ? error.message : String(error)}`);
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

  let root: string | null = null;
  let cursor = 0;
  let timer: ReturnType<typeof setInterval> | null = null;
  let delivering = false;

  const establishProject = (cwd: string) => {
    const next = projectRoot(cwd);
    if (next === root) return;
    root = next;
    cursor = root ? readLastSequence(root) : 0; // Start at the live edge; do not replay historical inbox events.
  };

  const poll = async () => {
    if (!root || delivering) return;
    const last = readLastSequence(root);
    if (last <= cursor) return;

    const events = readControlEvents(root, cursor);
    cursor = Math.max(cursor, last, ...events.map((event) => Number(event.sequence) || 0));
    const actionable = events.filter((event) => event.level === "attention" || event.level === "human_required");
    if (actionable.length === 0) return;

    delivering = true;
    try {
      await Promise.resolve(pi.sendMessage({
        customType: CONTROL_MESSAGE_TYPE,
        content: formatControlMessage(actionable),
        display: false,
        details: { firstSequence: actionable[0]?.sequence, lastSequence: actionable.at(-1)?.sequence },
      }, {
        triggerTurn: true,
        deliverAs: "followUp",
      }));
    } catch (error) {
      console.error(`[StatefulClanker extension] control-event delivery failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      delivering = false;
    }
  };

  pi.on("session_start", (_event, ctx) => {
    establishProject(ctx.cwd);
    if (!timer) timer = setInterval(() => void poll(), CONTROL_POLL_MS);
  });

  pi.on("agent_settled", (_event, ctx) => {
    establishProject(ctx.cwd);
    void poll();
  });

  pi.on("session_shutdown", () => {
    if (timer) clearInterval(timer);
    timer = null;
  });
}
