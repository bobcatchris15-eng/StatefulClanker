---
id: living-context
status: verified
tags: [context, memory, compaction]
paths: [context/, operator.ts, worker.ts]
links: [shared-checkouts]
---
# Living context protocol

All workers and the operator receive the same mutable foundation, with task-relevant Markdown passages selected via keyword, path overlap, and one-hop graph links.

The runtime silently recompiles its knowledge section before each Pi provider call. Long intermediate context is projected into a bounded recent window without deleting raw session history. Changing a Markdown document changes the next projection; no worker notification is sent.

Keep durable discoveries in the shared knowledge corpus before relying on them surviving history projection. See [[shared-checkouts]] for change ownership.
