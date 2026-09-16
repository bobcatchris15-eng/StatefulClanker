# Direct inference and the minimal worker harness

StatefulClanker supports two interchangeable worker backend types above the same task, Intent, freshness, critic, validator, and event machinery.

## CLI harness backend

A `cli` backend delegates the inner coding-agent loop to an installed tool such as Codex, Claude Code, Antigravity, OpenCode, Gemini, or another command-line harness.

```json
"opencode": {
  "type": "cli",
  "command": "opencode",
  "args": ["run"],
  "mode": "stdin"
}
```

This remains the preferred path when a provider's existing coding harness is useful or when consumer-subscription access is only exposed through that CLI.

## Direct API backend

An `api` backend points at a machine-local connection profile and uses StatefulClanker's intentionally small coding harness.

```json
"local-qwen": {
  "type": "api",
  "connection": "local-qwen"
}
```

Connection profiles are machine state, not project state, and live at:

```text
%LOCALAPPDATA%\StatefulClanker\connections.json
```

The Windows application exposes an **API Connections** tab for adding, editing, removing, testing, and attaching profiles to the active project. API keys entered there are encrypted with Windows DPAPI for the current user. A profile may instead name an environment variable so the key never enters the connection file.

## Intended endpoints

The first direct transport is OpenAI-compatible `/chat/completions`. That covers the main intended cases without coupling StatefulClanker to one vendor:

- Ollama (`http://127.0.0.1:11434/v1`)
- LM Studio (`http://127.0.0.1:1234/v1`)
- vLLM (`http://127.0.0.1:8000/v1`)
- OpenRouter (`https://openrouter.ai/api/v1`)
- custom OpenAI-compatible gateways and providers

The profile can override the chat path, add arbitrary HTTP headers, and merge extra request-body fields. This is useful for gateways and provider-specific routing options without adding brand-specific runtime code.

## Minimal harness

The built-in harness deliberately does less than a full Codex/Claude/OpenCode-style agent. StatefulClanker already owns planning, semantic decomposition, durable authority, context compilation, review, and project state.

The direct worker therefore receives one small system instruction plus the normal compiled truth packet, and only these bounded tools:

- `read_file`
- `search_text`
- `write_file`
- `replace_text`
- `run_command`
- `git_diff`
- `finish`

File operations are confined to the worker checkout. Command execution is bounded by timeout and runs in that checkout. The final worker output still flows through the ordinary critic/validator/freshness gates.

## Tool protocols

A connection chooses one of two tool protocols:

### `native`

Use OpenAI-compatible tool calls. This is the default for models/endpoints with reliable function calling.

### `text`

Use a strict one-JSON-object-per-turn protocol:

```json
{"tool":"read_file","arguments":{"path":"src/app.cs"}}
```

or:

```json
{"final":"Implemented the bounded task and tests pass."}
```

This fallback exists mainly for local models whose servers do not expose native tool calls reliably. It keeps the harness usable without teaching the runtime a provider-specific prompt dialect.

## Connection shape

Representative `connections.json`:

```json
{
  "schemaVersion": 1,
  "connections": {
    "local-qwen": {
      "name": "local-qwen",
      "baseUrl": "http://127.0.0.1:8000/v1",
      "model": "qwen3-coder",
      "toolMode": "native",
      "maxSteps": 24,
      "apiKeyEnv": null,
      "apiKeyProtected": null,
      "headers": {}
    },
    "openrouter-coder": {
      "name": "openrouter-coder",
      "baseUrl": "https://openrouter.ai/api/v1",
      "model": "provider/model-id",
      "toolMode": "native",
      "maxSteps": 24,
      "apiKeyEnv": "OPENROUTER_API_KEY",
      "headers": {}
    }
  }
}
```

## Routing

Routing continues to name project backends rather than model brands:

```json
"providerBySize": {
  "tiny": "local-qwen",
  "small": "local-qwen",
  "medium": "opencode",
  "large": "codex"
}
```

The task does not need to know whether `local-qwen` is local, remote, API-backed, or CLI-backed. The machine/project deployment configuration owns that choice.

## Security boundary

Direct API connections do not change project authority. API workers receive the same CURRENT human directives, reconciled Intent, task acceptance boundary, and source references as CLI workers. They cannot commit a stale result merely because the inference transport is different.

Project files may safely name a connection by ID, but secrets remain machine/user state and should never be written into `.statefulclanker` or committed to the repository.
