# Worker capabilities and external tools

StatefulClanker's built-in/direct-model worker loop has a runtime capability layer. It is intentionally separate from project Intent: Intent says **what the project means**; capability policy says **what a particular worker is allowed to touch while trying to satisfy it**.

The design borrows the useful shape of Agent Package Manager (APM): explicit MCP dependencies/tool exposure, secure-by-default behavior, and policy that becomes narrower as it approaches the consumer. StatefulClanker applies the same idea at runtime rather than only at install time.

## Authority layers

Effective access is the intersection of these layers:

```text
machine catalog / allow-list
    -> project policy
    -> role policy
    -> stage policy
    -> optional task toolPolicy
    -> advertised tool set for one worker invocation
```

Every lower layer is tighten-only. A repository may deny or narrow a machine capability, but cannot make a capability exist when the machine catalog did not grant it.

Denied tools are not merely rejected after a model calls them. They are removed from the tool definitions sent to the model. Invocation is checked again immediately before execution so a policy change during a run fails closed.

## Capability IDs

Built-in capabilities currently include:

```text
builtin.read_file
builtin.search_text
builtin.write_file
builtin.replace_text
builtin.run_command
builtin.git_diff
builtin.finish
intent.human.read
intent.normalized.read
```

External MCP tools use:

```text
mcp.<source>.<tool>
```

Examples:

```text
mcp.toaster.search
mcp.toaster.read_lesson
mcp.toaster.write_lesson
mcp.mempalace.search
```

The capability ID is the stable authorization name. OpenAI-compatible function names are encoded to safe wire names such as `mcp__toaster__search` only when presented to a direct model.

## Human authority tools

Direct-model workers can be given two separate read-only views:

### `intent.human.read`

Tool name: `read_human_intent`

Reads a durable `human:<id>` source reference, including optional line ranges. This is preserved direct evidence rather than an agent summary.

### `intent.normalized.read`

Tool name: `read_normalized_intent`

Reads the orchestrator-owned normalized Intent Contract plus the current direct-human directive snapshot.

Keeping these separate is deliberate. A worker may compare the conversational agent's interpretation against the direct human evidence without receiving authority to modify either one.

## Machine catalog

Machine-local worker capability state lives at:

```text
%LOCALAPPDATA%\StatefulClanker\worker-capabilities.json
```

Default state grants the built-in worker tools and the two read-only Intent capabilities. External MCP tools must be explicitly registered and allowed.

Representative shape:

```json
{
  "schemaVersion": 1,
  "allow": [
    "builtin.*",
    "intent.human.read",
    "intent.normalized.read",
    "mcp.toaster.search",
    "mcp.toaster.read_lesson"
  ],
  "deny": [],
  "sources": {
    "toaster": {
      "transport": "streamable-http",
      "url": "http://127.0.0.1:8765/mcp",
      "enabled": true,
      "headers": {
        "Authorization": "Bearer ${env:TOASTER_TOKEN}"
      }
    }
  }
}
```

Header values may use `${env:NAME}`. Secrets should remain machine/user environment state and must not be written into project policy.

Inherent-worker MCP currently supports HTTP / Streamable HTTP sources. The runtime accepts normal JSON responses and SSE `data:` responses and retains `Mcp-Session-Id` when the server supplies one.

A source may optionally declare a static `tools` array with MCP `name`, `description`, and `inputSchema`. If omitted, the inherent worker discovers tools with `tools/list` when building the authorized tool set.

## Project policy

Project restrictions live at:

```text
.statefulclanker\worker-policy.json
```

Example:

```json
{
  "schemaVersion": 1,
  "allow": [
    "builtin.*",
    "intent.*",
    "mcp.toaster.*"
  ],
  "deny": [
    "builtin.run_command",
    "mcp.toaster.write_lesson"
  ],
  "roles": {
    "critic": {
      "allow": [
        "builtin.read_file",
        "builtin.search_text",
        "intent.*",
        "mcp.toaster.search"
      ]
    }
  },
  "stages": {
    "validator": {
      "deny": ["mcp.*"]
    }
  }
}
```

A narrower task may also carry a `toolPolicy` object with the same `allow` / `deny` shape. This is optional; ordinary semantic tasks should normally inherit project/role/stage policy instead of micromanaging tools.

## Conversational-plane MCP controls

The resident StatefulClanker MCP exposes:

- `worker_policy_get` — inspect machine and project policy.
- `worker_policy_apply` — replace the project's tighten-only policy.
- `worker_source_set` — register/update a machine-local MCP source and optionally add explicit machine allow patterns.
- `worker_source_remove` — remove a source and its explicit machine allow entries.
- `worker_source_tools` — discover/list a source's MCP tools without granting them.

The conversational plane should use structured human clarification when tool access changes a real trust/risk boundary. Technical discovery itself is not a human question: discover the source/tool first, then ask only where the human's authorization or preference is genuinely required.

## Toaster / MemPalace pattern

A knowledge service should normally expose read/search separately from mutation. For example:

```text
mcp.toaster.search             allow
mcp.toaster.read_lesson        allow
mcp.toaster.write_lesson       deny for ordinary workers
mcp.toaster.ingest_manual      deny for ordinary workers
```

That lets cheap/local workers query durable expertise without automatically giving every worker permission to mutate the knowledge base. A specialist or post-success lesson-writing role can receive the narrower write capability when appropriate.

## CLI backends

This policy governs the **StatefulClanker-owned inherent/direct-model loop**. Provider-owned CLI harnesses retain their own tool model and permissions; StatefulClanker still controls their project/task/Intent/freshness/review boundaries, but does not pretend it can centrally revoke an internal Claude/Codex/OpenCode tool that the provider harness itself owns.

For equivalent restrictions in a provider CLI, configure that harness or launch profile accordingly.

## Receipts

Direct API worker telemetry and run receipts record the resolved capability IDs for the invocation. This makes tool exposure auditable alongside provider, model, task, compilation fingerprint, critic/validator results, and accepted state.
