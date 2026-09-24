import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { resolve } from "node:path";

const repo = resolve(import.meta.dirname, "..");
const require = createRequire(resolve(repo, "install", "pi-runtime", "node_modules", "@earendil-works", "pi-coding-agent", "package.json"));
const { createJiti } = require("jiti");
const extension = await createJiti(import.meta.url).import(resolve(repo, "pi", "extensions", "statefulclanker.ts"));
const handlers = new Map();
const messages = [];

await extension.default({
  on(name, handler) { handlers.set(name, handler); },
  registerTool() {},
  sendMessage(message) { messages.push(message); },
});

const beforeStart = handlers.get("before_agent_start");
assert.equal(typeof beforeStart, "function");
const event = { prompt: "Hello", systemPromptOptions: { sections: {} } };
beforeStart(event);
const guidance = event.systemPromptOptions.sections.statefulclanker;
assert.equal(typeof guidance, "string");
assert.match(guidance, /control_snapshot/);
assert.match(guidance, /task_recovery_context/);
assert.ok(guidance.length < 4000, `Startup guidance is too large: ${guidance.length} characters`);
assert.equal(messages.length, 0, "Startup injected a custom message into the interactive conversation");
console.log("PASS: bundled Pi extension injects curated model guidance without a visible custom message.");
process.exit(0);
