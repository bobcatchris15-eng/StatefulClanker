# Lab 5 finite-CSP cooperative feasibility preregistration

Date: 2026-10-01. This is a new exploratory task-family experiment, separate from Lab 4 affine work and the router 96-slot campaign. It uses two fixed model families, Liquid and North, through their copied Kilo Free allowlists. No prior Lab 4 response, private reasoning, answer, or transcript is supplied to any Lab 5 participant.

## Question and useful outcome

Can a small-model family use a compact shared claim/review protocol to enumerate local solution sets for a finite constraint problem and integrate them into a globally valid complete assignment, under the same resource envelope as its raw-facts control? Model-superiority or shared-state superiority is not the objective.

For descriptive feasibility, a family/condition is a useful run if at least 4 of its 6 final outputs are the unique valid global assignment. A cooperative complete case additionally requires both component proposals to be structurally accepted and each proposal to be sound and complete. Report shared and raw outcomes separately even if one condition reaches the threshold. Six instances and a selected finite CSP family do not estimate general capability or success probability.

## Public instances and hidden key

The six fixed instance seeds, in campaign order, are `5103, 5110, 5115, 5121, 5122, 5129`. Each public packet contains eight variables `a`–`h` with domain `{0,1,2,3}`, ten binary allowed-pair constraints, the left/right partition, the two bridge constraints, and the requirement to enumerate local sets then solve the complete assignment. Every role receives this full public packet. The selected instances have left/right local solution counts `5/3, 3/3, 5/4, 6/3, 3/3, 3/5`, and exactly one global assignment each. These properties are independently rechecked offline from public constraints. The planted assignments and exact expected tuple sets stay in `private/case-key.json`; they are not included in participant prompts or router request files.

Generation is fixed: Python `random.Random(seed)`, one planted eight-value assignment, four internal cycle edges per component, and bridges `(b,e)` and `(d,g)`. Each internal relation contains the planted ordered pair plus four sampled distinct alternatives; each bridge contains the planted pair plus one sampled distinct alternative. Scan candidate seeds in ascending order from 5101 and retain the first six satisfying both local-count bounds 3–10 and exactly one global solution. The selected seed list above is frozen; no replacement based on model performance is allowed.

## Calls, conditions, and schedule

There are exactly 72 planned fresh requests: 6 problems × 2 model families × 6 roles. Each role is one stateless single-user-message completion, with no carried conversation history. All calls use `maxOutputTokens=4096`, `temperature=0.6`, and a 180-second timeout. Every scheduled call consumes one slot when attempted, whether the provider succeeds, returns malformed output, or times out. No retry, repair, fallback model, answer hint, or evaluator feedback is permitted. Unattempted roles after interruption remain unattempted, not incorrect.

For each problem, family order alternates by instance index: Liquid then North for seeds 5103, 5115, and 5122; North then Liquid for seeds 5110, 5121, and 5129. Within each family/problem block, dispatch `left-proposer`/`right-proposer` concurrently; after both slots are recorded, dispatch `left-reviewer`/`right-reviewer` concurrently; after both reviews are recorded, dispatch `shared-integrator`/`raw-integrator` concurrently. A single resident endpoint may serialize paired requests; concurrent submission is not evidence of physical parallel inference. The six calls for each family/problem use that family's frozen allowlist/model only.

## Protocol and artifact policy

The adapter reuses the unchanged Lab 4 generic structural SQLite protocol. The domain payloads are limited to local tuple lists, structured review assessments and optional candidate tuple lists, and complete final assignments. The coordinator adds only scheduled identity, recipients, and pre-dispatch exact read references. It does not compute or patch any submitted answer. Candidate corrections remain visible and uncommitted. Rejected or malformed response bytes are retained before parsing and recorded with a fixed structural receipt; accepted state is replayable from the event log. No answer is promoted based on a coordinator's mathematical judgment.

Before any dispatch, freeze and hash the Lab 5 source, preregistration, six public cases, runtime discovery/package hashes supplied by the parent, Liquid and North allowlists/catalogs, schedule, protocol source, initial role prompts, and request policy. Save each later prompt and normalized request write-once and hash it before its pair starts. Use the reviewed FreeDispatch binary/runtime and retain its full request/response bodies, safe-header metadata, usage, finish reason, returned model and receipt. The only content passed to the protocol is the captured assistant content. Do not preserve or forward model reasoning fields to other roles.

Run the offline evaluator only after all 72 scheduled roles have a saved response or explicit failure record. Report exact global correctness for shared/raw conditions, accepted proposal rates, local tuple-set soundness/completeness, review assessments and candidate quality, structural attrition, timeouts and provider failures, and reported usage. Missing token usage stays missing. Preserve raw model output and structural validity as distinct outcomes.

## Interpretation boundary

This expands task-family coverage beyond affine fitting but is still a tiny finite CSP with eight variables, domain size four, and six preselected instances. It is not evidence that the problems are difficult for the isolated model, that performance scales to large CSPs, that an internal representation is universal, or that collaboration improves accuracy. No contribution-ablation condition is included. This is an exploratory feasibility measurement and an input to later benchmark design only.
