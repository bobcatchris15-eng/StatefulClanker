---
id: shared-checkouts
status: verified
tags: [git, concurrency, collaboration]
paths: [workspace/checkouts.ts, workspace/tools.ts, workspace/dispatch.ts]
links: [living-context]
---
# Shared checkout protocol

Workers use a single working tree. A checkout grants right-of-way to write and publish; anyone can read. Other workers submit proposals to the owner. Publication is serialized through the checkout broker and scoped to owned paths. Do not use broad git staging or ad hoc commits.

See also [[living-context]] for how context updates cross worker boundaries.
