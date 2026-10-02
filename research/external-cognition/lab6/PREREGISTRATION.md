# Lab 6 16-Variable Ring Finite-CSP Cooperative Feasibility Preregistration

Date: 2026-10-02. This is an exploratory task-family scaling experiment expanding beyond Lab 5's 8-variable domain to 16 variables in a 4-component ring topology. It tests whether multi-agent component decomposition with a structured SQLite claim/review protocol can solve finite constraint satisfaction problems that are computationally infeasible for monolithic single-prompt reasoning.

## Question and Useful Outcome

Can a model family use a compact shared claim/review protocol to decompose a 16-variable finite CSP with search space $4^{16} \approx 4.3 \times 10^9$ into four 4-variable components ($4^4 = 256$ search space each) and assemble them across a 4-bridge closed ring topology into a unique global assignment, where the raw monolithic control fails due to combinatorial explosion?

For descriptive feasibility:
- Useful run threshold: at least 3 of 6 final outputs in the shared condition match the unique planted global solution.
- Decisive separation: shared integrator accuracy strictly exceeds raw integrator accuracy ($\Delta \ge 2/6$).

## Public Instances and Hidden Key

The six fixed instance seeds, in campaign order, are `6112, 6135, 6412, 6432, 6459, 6582`. Each public packet contains sixteen variables `a` through `p` with domain `{0,1,2,3}`, twenty binary allowed-pair constraints (16 internal cycle edges and 4 ring bridge edges), the four-component partition, and the requirement to enumerate local sets and solve the complete assignment.

Every role receives this full public packet. The selected instances each have:
- Exactly four components ($C_1, C_2, C_3, C_4$) of four variables each.
- Local solution counts between 3 and 8 for every component.
- Exactly one global solution across all 16 variables.

The planted assignments and exact expected tuple sets remain in `private/case-key.json`; they are not included in participant prompts or router request files.

## Calls, Conditions, and Schedule

Each model family evaluated completes 6 problems × 10 roles = 60 call slots:
- 4 Proposers: `c1-proposer, c2-proposer, c3-proposer, c4-proposer`
- 4 Reviewers: `c1-reviewer, c2-reviewer, c3-reviewer, c4-reviewer`
- 2 Integrators: `shared-integrator, raw-integrator`

All calls use `maxOutputTokens=16384`, `temperature=0.6`, and a 180-second timeout. Every scheduled call consumes one slot when attempted. No retry, repair, fallback model, answer hint, or evaluator feedback is permitted.

Within each problem block:
1. Dispatch the 4 proposers concurrently (`max_workers=4`).
2. After all 4 proposer slots are recorded, dispatch the 4 reviewers concurrently (`max_workers=4`).
3. After all 4 reviewer slots are recorded, dispatch `shared-integrator` and `raw-integrator` concurrently.

## Protocol and Artifact Policy

The adapter reuses the unchanged Lab 4 generic SQLite protocol. The domain payloads are limited to 4-tuple lists, structured review assessments across bridges, and complete 16-variable final assignments. The coordinator adds only scheduled identity, recipients, and pre-dispatch exact read references. It does not compute or patch any submitted answer.

Before any dispatch, freeze and hash the Lab 6 source, preregistration, six public cases, runtime discovery/package hashes, transport allowlists/catalogs, schedule, protocol source, initial role prompts, and request policy. Use the reviewed FreeDispatch binary and retain its full request/response bodies, metadata, usage, finish reason, and receipt.

Run the offline evaluator only after all scheduled roles have a saved response or explicit failure record.
