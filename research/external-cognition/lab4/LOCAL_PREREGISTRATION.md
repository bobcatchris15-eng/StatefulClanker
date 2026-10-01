# Local Qwen replication: frozen plan before inference

Date: 2026-10-01. User supplied a running local Qwen 9B through Lemonade and authorized continued cooperative-engine investigation. Discovery identified qwen3.5-9b-FLM, checkpoint qwen3.5:9b, FLM NPU backend, Lemonade 11.9.0, initial configured context 8192, then user-adjusted ready context 70728 before freeze. No downloads, server reconfiguration or alternate models are part of this replication.

## Question and success criterion

Can the existing provider-neutral protocol carry cooperative reasoning by this actual local model? Primary observations are envelope compliance, independent part proposals, useful cross-review, and valid final solutions. Comparative superiority is not required. Two successful final cases would support local feasibility on this toy task; partial success is recorded transparently. This is not the promised harder-task benchmark or a statistical estimate. A later useful-success threshold (including an illustrative 50%) requires an explicitly defined benchmark and resource envelope.

## Fixed design

Replicate Lab4 seeds 4201 and 4202 with exactly twelve fresh, stateless chat requests: parallel u/v proposers, parallel cross-reviewers, then parallel shared/raw integrators for each case. Use the unchanged pilot.py and protocol.py and their frozen native-campaign hashes. Every participant gets the complete public problem; the shared integrator additionally gets structured claims, reviews and candidate values. Reviews and candidate values are not selected or corrected by the coordinator. No participant receives hidden ground truth, evaluator feedback, other-role private reasoning or a prior chat history.

Use model qwen3.5-9b-FLM, temperature 0, max_tokens 4096, stream false, and a single user message containing the saved role prompt. Lemonade may identify the same loaded model in a completion response by either its exact frozen model ID (`qwen3.5-9b-FLM`) or exact frozen checkpoint (`qwen3.5:9b`); both are recorded distinctly, and any other returned model name fails that slot. No JSON-format repair, markdown stripping, constrained-output add-on, retries, alternate samples, semantic patch or replacement participant. Save complete outgoing JSON request and complete HTTP response before extracting final content. Save provider reasoning fields in raw transport evidence, but pass only the supplied final envelope through the protocol. Truncated, empty, malformed or failed responses consume their slot. Transport timeout is 300 seconds and is a failure; record it without retry. Readiness is checked before any inference and must match the frozen loaded model/backend/context. An incomplete attempted run is not automatically restarted, avoiding duplicate inference requests. Slots absent due to a coordinator crash are unattempted and must not be confused with failed inference.

Each parallel pair is concurrently submitted; the backend may serialize inference. Request timestamps and observed overlap do not prove physical parallel model execution. A single resident model supplies independent participant contexts, rather than separate resident model copies.

## Freeze, measurement and evaluation

Before the first inference, freeze hashes of implementation, this plan, case packets, role schedule, initial prompts, discovery/model metadata and request policy in a separate local run directory. Save and hash later prompts before dispatch. Persist exact request/response bytes, content bytes, structural receipts, usage when supplied, finish reasons, wall-clock durations, and failures. Do not reinterpret missing usage as zero. Verify the server reports the requested model already ready; do not change its residency or configuration.

Only after all twelve slots are recorded, run the existing offline evaluator and independent arithmetic audit. Report each case and each final condition, proposal accuracy, review correctness, transport/schema attrition, resource metadata and replay/hash integrity. A correct raw answer rejected by the protocol is distinct from a valid cooperative result. Keep native and local results separate; no native/local causal comparison is implied by using the same cases.

## Known limits

The coordinator already knows these cases from the completed native pilot; local participants receive only frozen permitted facts, and the design/adapter must not select or repair their outputs. Case selection predates local readiness. A 70728-token server configuration and a 4096-token requested output allowance are recorded, not a guarantee of actual context allocation or identical sampling across backends. This tests structured JSON state rather than a universal or learned opaque reasoning representation. Stale-fork behavior remains mechanically tested, not exercised by the native or local twelve-slot schedule.
