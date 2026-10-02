# Lab 5: finite constraint decomposition

## Aim

Test a second task family for cooperative small-model reasoning: enumerate local solution sets for two coupled finite constraint components, review the peer's enumeration, and combine both sets with bridge constraints into a complete assignment. The experiment measures useful cooperative feasibility and resource cost. It does not require shared-state performance to exceed the raw-facts control.

## Fixed problem family

Each problem has eight variables `a` through `h`, each in `{0,1,2,3}`. The left component is `(a,b,c,d)` and the right component `(e,f,g,h)`. Each component contains four binary allowed-pair constraints arranged as a cycle; two binary bridge constraints connect `(b,e)` and `(d,g)`. A constraint is satisfied only when the ordered variable values occur in its public `allowed_pairs` list. Participants receive the entire public packet, including both components and both bridges.

An offline generator plants one assignment, creates the ten relations, exhaustively enumerates each local component and the global CSP, and retains the first six candidate seeds whose local counts are each 3–10 and whose global solution count is exactly one. The planted assignment is never written in public packets. It is retained in a separate evaluator-only key file, and independent tests recompute all counts from public constraints. The frozen selected seeds are `5103, 5110, 5115, 5121, 5122, 5129`; their local solution-count pairs are `5/3, 3/3, 5/4, 6/3, 3/3, 3/5`, respectively, and each has one global solution.

## Roles and state

Each model-family/problem pair uses six new stateless calls. `left-proposer` and `right-proposer` simultaneously submit complete sorted local tuple lists in disjoint `PROPOSE` claims. `left-reviewer` examines the right claim and `right-reviewer` examines the left claim in a parallel pair. Reviewers return `CHALLENGE` or `REPORT_EVIDENCE` with a structured assessment and constraint-ID basis; an optional corrected tuple-list claim remains a visible uncommitted candidate. `shared-integrator` gets the full problem and the protocol projection with original claims, reviews, and candidates; `raw-integrator` gets the same full public problem without those messages. Both produce a complete eight-variable assignment independently and in parallel.

The existing Lab 4 standard-library SQLite protocol is imported unchanged. The Lab 5 adapter inserts envelope identity, routing, and the exact current read references before the call. It performs structural envelope/role checks and persists exact response bytes before parsing. It does not check tuple correctness, choose a candidate, solve the CSP, or provide semantic feedback. Operational claim states do not mean mathematical truth. Stale proposals keep the generic protocol's potential-fork behavior.

## Offline checks and separation

`generate_cases.py` creates the six public packets and private key before a run is prepared. Live prompt compilation and submission modules do not import the generator or evaluator. `offline_evaluate.py` is invoked only after the 72 scheduled roles each have a response or recorded failure. It checks local tuple-set soundness and completeness, review dispositions/candidates, full-assignment validity and exact global correctness, protocol acceptance, and transport/schema attrition. It also reports token usage only when the provider supplied it. The evaluator reads the private answer key and independently enumerates public constraints; it cannot change any participant message or receipt.

## Files

- `generate_cases.py`: deterministic case generation and private answer-key generation; never imported by the live pilot.
- `cases/`: public selected problem packets only.
- `private/case-key.json`: evaluator-only selected solutions and expected local sets.
- `pilot.py`: run freeze, prompt compiler, response submission, failure recording, launcher, and evaluation gate; no generator/oracle import on its live path.
- `offline_evaluate.py`: oracle-backed scoring invoked after all slots exist.
- `tests/`: offline invariants, protocol/route and stale-read coverage, fake FreeDispatch invocation, slot/failure behavior, and freeze/hash checks.

The run freezes Lab 5 sources, the unchanged protocol source, selected preregistration, runtime package, both copied allowlists and catalogs, six public cases, schedule, and initial proposer prompts. Later role prompts and normalized requests are write-once and hashed before their dispatch pair. Runtime calls use the reviewed `FreeDispatch` CLI and its exact receipt/artifact contract.
