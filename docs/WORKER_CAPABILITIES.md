# Worker capabilities and external tools

StatefulClanker's inherent/direct-model worker loop has a runtime capability layer separate from project Intent. Intent says **what the project means**; capability policy says **what a worker may do while satisfying it**.

The model is inspired by APM's explicit MCP/tool exposure and tighten-only governance, but authorization is enforced at runtime.

## Effective authorization

```text
machine allow/deny
  -> optional named capability profile
  -> project allow/deny
  -> role allow/deny
  -> stage allow/deny
  -> task-local allow/deny
  -> advertised tools for one invocation
```

Every lower layer only narrows. Deny wins. A denied tool is removed from the model-visible tool list and authorization is checked again immediately before invocation.

## Capability IDs

Built-ins:

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

External MCP tools use stable ids:

```text
mcp.<source>.<tool>
```

Examples: `mcp.toaster.search`, `mcp.toaster.write_lesson`, `mcp.mempalace.search`.

## Separate human/normalized authority readers

`intent.human.read` (`read_human_intent`) reads preserved direct `human:<id>` evidence.

`intent.normalized.read` (`read_normalized_intent`) reads the orchestrator-owned reconciled Intent Contract plus the current Human Directive snapshot.

Both are read-only. Keeping them separate lets a worker verify interpretation against direct wording without gaining authority to rewrite either.

## Machine catalog

Machine capability state lives at:

```text
%LOCALAPPDATA%\StatefulClanker\worker-capabilities.json
```

Schema v2:

```json
{
  "schemaVersion": 2,
  "allow": [
    "builtin.*",
    "intent.human.read",
    "intent.normalized.read",
    "mcp.toaster.search"
  ],
  "deny": ["builtin.run_command"],
  "profiles": {
    "research-readonly": {
      "allow": [
        "builtin.read_file",
        "builtin.search_text",
        "intent.*",
        "mcp.toaster.search"
      ],
      "deny": []
    }
  },
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

Machine allow/deny is the maximum authority. A named profile is reusable narrowing, not a grant mechanism.

## Capability profiles

Profiles are useful when many tasks need the same bounded environment:

```text
coding
research-readonly
critic-safe
no-shell
```

A task selects one with:

```text
capability-profile research-readonly
```

or MCP/CLI `capabilityProfile` / `-CapabilityProfile`.

If the named profile does not exist on the executing machine, dispatch fails closed. A profile's `allow` cannot escape the machine allow-list because machine authorization is checked first.

## Project policy

Project restrictions live at:

```text
.statefulclanker\worker-policy.json
```

Project, role and stage policy only narrow machine/profile authority.

```json
{
  "schemaVersion": 1,
  "allow": ["builtin.*", "intent.*", "mcp.toaster.*"],
  "deny": ["builtin.run_command", "mcp.toaster.write_lesson"],
  "roles": {
    "critic": {
      "allow": ["builtin.read_file", "builtin.search_text", "intent.*", "mcp.toaster.search"]
    }
  },
  "stages": {
    "validator": { "deny": ["mcp.*"] }
  }
}
```

## Task-local narrowing

`SCPLAN 1` and `task_add` make task policy first-class:

```text
capability-profile research-readonly
tool-allow intent.*
tool-allow mcp.toaster.search
tool-deny builtin.run_command
```

The persisted task contains `capabilityProfile` and `toolPolicy`. These fields participate in the task-definition hash, so changing worker authority invalidates old compiled work.

## External MCP sources

External services are registered machine-locally. A source may declare a static MCP `tools` array or allow runtime `tools/list` discovery.

Source registration does not grant every tool. The machine allow-list must include the desired `mcp.<source>.<tool>` patterns.

Header values may use `${env:NAME}` so secrets remain machine/user state.

The inherent-worker MCP client currently supports HTTP/Streamable HTTP sources and legacy handshake-era MCP behavior for those downstream tools. Provider-owned CLI backends retain their own internal tool/client implementations.

## Conversational-plane management

MCP exposes:

- `worker_policy_get`
- `worker_policy_apply`
- `worker_source_set`
- `worker_source_remove`
- `worker_source_tools`
- `worker_profile_set`
- `worker_profile_remove`

Profile and project policy setters validate that explicit allow patterns do not broaden machine authority.

## Windows app

The native app exposes a **Worker Capabilities** page showing/editing:

- machine allow/deny patterns;
- named capability profiles;
- registered external MCP tool sources;
- source-specific machine grant patterns;
- the active project's `worker-policy.json`.

The UI edits the same files the runtime consumes; it is not a second authorization system.

## Toaster/MemPalace pattern

Knowledge services should separate read/search from mutation where possible:

```text
mcp.toaster.search          allow ordinary workers
mcp.toaster.read_lesson     allow ordinary workers
mcp.toaster.write_lesson    deny ordinary workers
mcp.toaster.ingest_manual   deny ordinary workers
```

A specialist or lesson-writing task can use a narrower profile that includes the write capability if the machine owner granted it.

## CLI backend boundary

This policy controls the StatefulClanker-owned inherent worker loop. External Codex/Claude/OpenCode/etc. harnesses own their internal tool permissions. StatefulClanker still controls task authority, context, freshness and acceptance around those runs, but cannot centrally revoke tools hidden inside another harness.

## Auditability

Direct-worker telemetry/run receipts record the resolved capability ids for each invocation, alongside task/backend/model/compilation metadata. Tool exposure can therefore be reconstructed after the fact.
