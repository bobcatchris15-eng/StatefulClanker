# Direct inference and the inherent worker harness

StatefulClanker supports two interchangeable worker backend types above the same Current Human Directives, reconciled Intent, task graph, freshness, critic/validator and event machinery.

## CLI backend

A `cli` backend delegates the inner coding-agent loop to an installed provider/local harness such as Codex, Claude Code, OpenCode, Antigravity, Gemini CLI, or another configured command.

## API backend

An `api` backend points at a machine-local inference connection and uses StatefulClanker's intentionally small inherent harness.

Machine connection profiles live at:

```text
%LOCALAPPDATA%\StatefulClanker\connections.json
```

The Windows **API Connections** page can add/edit/remove/test connections and attach them to the active project. Secrets are DPAPI-encrypted for the current Windows user or referenced by environment variable. Project state stores only a connection id.

For OpenRouter, the app provides a single **OpenRouter API Key** field. Saving it generates the built-in free-model connection catalog with the official OpenRouter base URL; the same protected credential is reused across those managed profiles, so model selection does not require repeated key or endpoint setup.

## Protocol adapter

The implemented direct protocol is `openai-chat`, using OpenAI-compatible `/chat/completions`.

Primary intended targets include Ollama, LM Studio, vLLM, OpenRouter, and arbitrary compatible local/remote gateways. Profiles may override path/headers/request-body fields. Unsupported protocol names fail closed so another native API dialect can be added later without changing task semantics.

## Inherent harness responsibilities

The inherent harness owns only the bounded inner execution loop. StatefulClanker already owns planning, durable authority, context compilation, routing and acceptance.

Built-in tool capabilities include:

```text
builtin.read_file
builtin.search_text
builtin.write_file
builtin.replace_text
builtin.run_command
builtin.git_diff
builtin.finish
```

The actual tool list presented to a worker is **dynamic** and authorization-driven. It may additionally contain:

```text
intent.human.read
intent.normalized.read
mcp.<source>.<tool>
```

Denied capabilities are omitted from model-visible tool definitions and checked again on invocation.

A task can select a named capability profile and narrow it further with task-local `tool-allow` / `tool-deny`. See `WORKER_CAPABILITIES.md`.

## Tool interaction modes

### `native`

Uses OpenAI-compatible native tool calls.

### `text`

For local models/servers without reliable function calling, the model emits one compact JSON object per turn:

```json
{"tool":"read_file","arguments":{"path":"src/app.cs"}}
```

or finishes with:

```json
{"final":"Implemented the bounded task and verified the requested behavior."}
```

The available tool names are supplied from the same resolved capability registry used by native mode; text mode does not bypass authorization.

## Authority visibility

Direct workers receive Current Human Directives and reconciled Intent in their compiled truth packet. When policy permits they can independently inspect:

- preserved verbatim human source evidence (`read_human_intent`);
- the orchestrator's normalized Intent/current directive view (`read_normalized_intent`).

This lets a worker verify interpretation without gaining write authority over either layer.

## External MCP tools

Machine-local services such as Toaster or MemPalace may be registered as worker MCP sources. Their tools become candidate capabilities like `mcp.toaster.search`; registration alone does not authorize them.

This is especially useful for small/local models: the direct loop can expose a narrow repository/tool surface plus targeted durable expertise without importing a third-party coding harness system prompt or memory model.

## Routing

Routing names project backends rather than model brands:

```json
{
  "providerBySize": {
    "tiny": "local-qwen",
    "small": "local-qwen",
    "medium": "opencode",
    "large": "codex"
  },
  "providers": {
    "local-qwen": { "type": "api", "connection": "local-qwen" },
    "opencode": { "type": "cli", "command": "opencode", "args": ["run"], "mode": "stdin" }
  }
}
```

The same semantic task may move between API and CLI backends without changing project authority.

## Security boundary

`builtin.run_command` is high-trust: it has the OS privileges of the worker process. External write/action MCP tools can be similarly powerful. Use machine deny rules, named profiles, project narrowing and task-local restrictions to keep ordinary local-model workers bounded.

API transport does not weaken freshness. A direct worker cannot commit work compiled against superseded human/Intent/task authority merely because its inference path is local.
