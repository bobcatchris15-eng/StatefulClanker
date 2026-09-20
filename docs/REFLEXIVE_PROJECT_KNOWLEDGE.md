# Reflexive Project Knowledge (RPK)

RPK is StatefulClanker's project-local, reflexive working memory. It combines a cheap deterministic codebase graph with small lessons learned while actually working on the project. It is deliberately **candidate context**, never specification authority.

## Storage

Each project owns one SQLite database:

```text
<project>\.clanker\reflexive-project-knowledge.sqlite
```

The database is private project state and should normally remain uncommitted. It contains:

- file path, content hash, size, language and modification metadata;
- lightweight symbols and deterministic reference edges;
- lessons with status, confidence, source, tags and linked paths;
- the file hashes that were current when each path-linked lesson was confirmed.

The implementation lives in the native Windows host and uses `Microsoft.Data.Sqlite`. The PowerShell runtime talks to the same executable through its `--rpk` command mode, so there is no Graphify/Python runtime dependency and no separate Toaster service.

## Indexing and graph behavior

Before context compilation, RPK incrementally scans text/code files. Unchanged content hashes are skipped. Changed files have their symbols/reference edges rebuilt. Deleted files are removed from the graph.

This is intentionally boring and deterministic. The first implementation extracts common symbols from C#, PowerShell, Python and JavaScript/TypeScript and records import/reference-like edges. It is not intended to replace a compiler or language server; it gives workers cheap topology and stable anchors before spending inference.

Workers can call `project_graph_neighbors` to inspect graph adjacency.

## Lessons: project muscle memory

Authorized inherent workers receive:

- `project_knowledge_search`
- `project_graph_neighbors`
- `project_lesson_write`
- `project_lesson_confirm`
- `project_lesson_reject`

The default machine policy enables `rpk.*`. Existing pre-RPK machine policy is migrated once to include that namespace; project/role/stage/task policy can still tighten or deny it.

Workers are instructed to write lessons for durable **project-specific** discoveries: file/process traps, API quirks, corrections after a failed approach, important relationships, or implementation rules future workers are likely to trip over. Generic programming advice and guesses do not belong here.

Useful lessons should carry narrow tags and project-relative paths. Path links are what make deterministic staleness useful.

## Retrieval

Compilation indexes the project and retrieves a bounded set of lessons using task title, instruction, acceptance criteria and concrete retrieval paths. The resulting `sources.reflexiveProjectKnowledge` section is explicitly marked candidate working knowledge.

Authority remains:

1. current direct human directives;
2. reconciled normalized Intent;
3. current project evidence;
4. RPK lessons.

A stale or incorrect lesson must never override the first three.

## Reflexive normalization

Every time critic evidence lands, StatefulClanker:

1. incrementally re-indexes the current project;
2. compares path-linked lessons with the current file hashes;
3. marks lessons whose linked files changed as `needs_review`;
4. leaves them retrievable but visibly stale until an authorized worker checks current evidence and confirms or rejects them.

This is the deterministic half of "is this lesson still applicable?" The semantic half belongs to the critic/worker that can inspect the changed code. RPK does not pretend a hash comparison can decide meaning.

Rejected lessons remain durable evidence but are excluded from ordinary retrieval.

## Design boundary

RPK replaces the need to bolt Toaster or Graphify onto every StatefulClanker project for these two jobs. External MCP knowledge sources are still supported for genuinely external or cross-project knowledge.

RPK itself is intentionally project-scoped. Cross-project reusable expertise is a different state class and should not silently bleed into a project's muscle memory.
