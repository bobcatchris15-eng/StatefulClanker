import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, renameSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { createInterface } from "node:readline";
import { createRequire } from "node:module";

const repo = resolve(import.meta.dirname, "..");
const require = createRequire(join(repo, "install", "pi-runtime", "node_modules", "@earendil-works", "pi-coding-agent", "package.json"));
const { createJiti } = require("jiti");
const extensionPath = join(repo, "pi", "extensions", "statefulclanker.ts");
// Expose the real parser only in this test module; production has no test API.
const extension = createJiti(import.meta.url).evalModule(readFileSync(extensionPath, "utf8") + "\nexport { StdioMcpClient };", { filename: extensionPath });
const parser = Object.create(extension.StdioMcpClient.prototype);
parser.stdoutBuffer = "";
let rejected = false;
parser.pending = new Map([[1, { reject() { rejected = true; } }]]);
const errors = [];
const originalError = console.error;
console.error = text => errors.push(String(text));
try { parser.acceptStdout('{"broken":"' + "private historical content ".repeat(20000) + "\n"); }
finally { console.error = originalError; }
assert.ok(errors.join("\n").length < 512, "Malformed MCP response flooded the terminal with the raw payload");
assert.ok(!errors.join("\n").includes("private historical content"), "Malformed-response diagnostics leaked event content");
assert.ok(rejected, "Malformed response left the startup RPC hanging");
console.log("PASS: malformed responses produce bounded diagnostics and reject pending calls.");
const project = mkdtempSync(join(tmpdir(), "sc-pi-stdio-"));
const state = join(project, ".statefulclanker");
mkdirSync(join(state, "control"), { recursive: true });
writeFileSync(join(state, "state.json"), "{}");
writeFileSync(join(state, "control", "state.json"), JSON.stringify({ lastSequence: 300 }));
const message = 'Review “Integration & Acceptance” — café 日本語';
writeFileSync(join(state, "control", "events.jsonl"), Array.from({ length: 300 }, (_, i) => JSON.stringify({
  sequence: i + 1, level: "attention", type: "validator.finished", message,
  data: { note: "historical context ".repeat(100) },
})).join("\n") + "\n");

// Match Pi's hidden, piped Windows PowerShell child, which can otherwise use
// an ASCII best-fit encoding and turn smart quotes into unescaped JSON quotes.
const child = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
  join(repo, "mcp", "StatefulClanker.Mcp.ps1"), "-ProjectPath", project], {
  cwd: project, windowsHide: true, stdio: ["pipe", "pipe", "pipe"],
});
const lines = createInterface({ input: child.stdout });
let nextId = 1;
const pending = new Map();
lines.on("line", line => {
  let envelope;
  try { envelope = JSON.parse(line); }
  catch (error) {
    for (const request of pending.values()) request.reject(new Error(`Invalid MCP JSON (${line.length} characters): ${error.message}`));
    pending.clear();
    return;
  }
  const request = pending.get(envelope.id);
  if (!request) return;
  pending.delete(envelope.id);
  if (envelope.error) request.reject(new Error(envelope.error.message));
  else request.resolve(envelope.result);
});
function rpc(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`MCP ${method} timed out`)); }, 10000);
    pending.set(id, { resolve: value => { clearTimeout(timeout); resolve(value); }, reject: error => { clearTimeout(timeout); reject(error); } });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}
function payload(result) { return JSON.parse(result.content.find(item => item.type === "text").text); }
try {
  await rpc("tools/list", {});
  const history = payload(await rpc("tools/call", { name: "control_events_since", arguments: { since: 0, limit: 250 } }));
  assert.equal(history.events.length, 250);
  assert.equal(history.events[0].message, message, "Hidden MCP child altered Unicode event text");
  console.log("PASS: hidden Pi MCP transport preserves Unicode and valid JSON.");
  const edge = payload(await rpc("tools/call", { name: "control_events_since", arguments: { cursorOnly: true } }));
  assert.equal(edge.cursor, 300);
  assert.deepEqual(edge.events, [], "Startup cursor read fetched historical events");
  console.log("PASS: startup reads only the live cursor, without historical payloads.");

  // At the live edge, no new events exist. Make the history unreadable to prove
  // idle polling does not re-open and parse the entire historical log.
  const historyPath = join(state, "control", "events.jsonl");
  renameSync(historyPath, historyPath + ".saved");
  mkdirSync(historyPath);
  try {
    const idle = await rpc("tools/call", { name: "control_events_since", arguments: { since: 300 } });
    assert.ok(!idle.isError, "Idle Pi polling unnecessarily read historical event storage");
    assert.deepEqual(payload(idle).events, []);
  } finally {
    rmSync(historyPath, { recursive: true });
    renameSync(historyPath + ".saved", historyPath);
  }
  console.log("PASS: idle polls at the live cursor do not scan historical events.");

  const calls = [];
  const clients = new Set();
  const timers = [];
  const originalRpc = extension.StdioMcpClient.prototype.rpc;
  const originalInterval = globalThis.setInterval;
  const originalCwd = process.cwd();
  let delayPolls = false;
  let delayedPolls = 0;
  let releasePolls;
  const pollGate = new Promise(resolve => { releasePolls = resolve; });
  const pollCompletions = [];
  extension.StdioMcpClient.prototype.rpc = async function(method, params) {
    clients.add(this);
    let complete = () => {};
    if (delayPolls && params?.name === "control_events_since") {
      delayedPolls++;
      pollCompletions.push(new Promise(resolve => { complete = resolve; }));
      await pollGate;
    }
    try {
      const result = await originalRpc.call(this, method, params);
      calls.push({ method, params, result });
      return result;
    } finally { complete(); }
  };
  globalThis.setInterval = (...args) => { const timer = originalInterval(...args); timers.push(timer); return timer; };
  try {
    process.chdir(project);
    const handlers = new Map();
    const messages = [];
    await extension.default({ on(name, handler) { handlers.set(name, handler); }, registerTool() {}, sendMessage(message) { messages.push(message); } });
    await handlers.get("session_start")({}, { cwd: project });
    const startupReads = calls.filter(call => call.params?.name === "control_events_since");
    assert.equal(startupReads.length, 1);
    assert.deepEqual(payload(startupReads[0].result).events, [], "Pi session startup transferred historical event payloads");
    assert.ok(JSON.stringify(startupReads[0].result).length < 512, "Pi startup cursor response exceeded its budget");
    assert.deepEqual(messages, [], "Pi startup replayed historical events into the conversation");
    console.log("PASS: actual Pi session startup uses a bounded cursor response with no history replay.");
    delayPolls = true;
    handlers.get("agent_settled")({}, { cwd: project });
    handlers.get("agent_settled")({}, { cwd: project });
    assert.equal(delayedPolls, 1, "A slow event poll queued overlapping RPCs behind the startup connection");
    console.log("PASS: slow control polls cannot queue overlapping requests.");
  } finally {
    for (const timer of timers) clearInterval(timer);
    releasePolls();
    await Promise.all(pollCompletions);
    globalThis.setInterval = originalInterval;
    extension.StdioMcpClient.prototype.rpc = originalRpc;
    process.chdir(originalCwd);
    await Promise.all([...clients].map(client => new Promise(resolve => {
      client.child.once("close", resolve);
      client.close();
    })));
  }
} finally {
  lines.close();
  child.kill();
  await new Promise(resolve => child.once("close", resolve));
  rmSync(project, { recursive: true, force: true });
}
