# Free-provider breadth campaign 1

Registered before any experimental inference. Setup probes are separate transport checks and do not contribute to accuracy scores.

## Question and success criteria

Can several small or sparsely active model families participate in a shared external reasoning workspace using fresh requests, parallel independent contributions, cross-review, and deterministic communication envelopes? Useful cooperative performance is the goal; superiority over the raw-facts control is not required. Successful execution means all scheduled slots have durable outcomes, including errors, and independent evaluation can reconstruct what occurred. Positive reasoning performance is a separate result.

The first breadth campaign is descriptive calibration on the two existing public affine problems, not evidence of harder-task capacity, general 50% accuracy, or internal context limitations. If calibration works, a subsequent independently frozen benchmark should broaden tasks and seeds. Preserve this campaign even if later changes improve results.

## Participants and schedule

Four selected families: Liquid LFM 2.5 2.6B, Cohere North Mini Code, Poolside Laguna XS 2.1, and NVIDIA Nemotron 3 Nano Omni 30B A3B Reasoning. Distinguish dense parameter counts from total and active MoE parameters. All selected routes are Kilo free routes. The original Gemma/OpenRouter candidate returned HTTP429 during the separate readiness probe and was replaced before experimental freeze; its exact failure remains retained. The Nemotron replacement passed a readiness probe. Current public catalog entries must have the exact selected `:free` identifier and zero prompt/completion prices; Kilo entries must also explicitly be free. No paid route or generic automatically selected model is allowed.

Readiness probes determine supported routes and exact returned-model aliases before freezing. An unavailable candidate may be replaced only before freeze, with the reason and catalog evidence recorded. After freeze, errors consume their slots; no replacements, retries, migration, or silent exclusions.

Each family has two separate representations, `full` and `payload`, each with seeds 4201 and 4202 and six fresh roles per seed. This gives 4 × 2 × 2 × 6 = 96 scheduled primary requests. Per case: parallel u/v proposals; parallel cross-reviews; parallel shared-state and raw-facts final integrators. Each pair completes before preparing the next phase. Conditions execute sequentially in a recorded order fixed before dispatch. Each provider call uses one fresh user message, maximum 4096 output tokens, temperature 0.6, and a 180-second timeout. These settings are requested values; actual provider support and usage are recorded.

## Representation contrast

Both representations include identical complete public problem facts. Full representation asks the model to produce the existing protocol envelope. Payload representation asks for a compact purpose-specific JSON payload; the runner supplies known role identity, routing, schema, pinned read references, and claim metadata deterministically. It never solves the mathematics, repairs model content, selects a better candidate, or validates semantic correctness before the final scoring gate.

The payload compiler rejects duplicate keys, noninteger numeric values, booleans where integers are required, unknown fields, and out-of-range values. Exact raw content is saved first. Compiled envelopes are separate artifacts with raw and compiled hashes and compiler source identity. Malformed outputs and transport failures are recorded, consume their slot, and receive no corrective inference.

Shared integrators receive the actual accepted authored proposals, cross-reviews, and candidates. Raw integrators receive the same complete facts without these peer contributions. No coordinator-authored solution or correctness feedback reaches participants. Separate state stores prevent representation and family leakage.

## Evidence and analysis

Freeze source snapshots, generator/protocol/pilot/compiler hashes, dispatcher source/build identities, allowlists and their catalog hashes, preregistration, condition schedule, requested settings, accepted returned-model aliases, and initial prompts. Save dynamic prompts and request bytes before dispatch. Preserve complete response bytes, exact assistant content, safe transport metadata, HTTP errors, timeout status, duration, and provider usage. Do not retain credentials or authorization header values.

Evaluate only after the required outcome gate. Report proposal accuracy, review quality, protocol/payload validity, shared and raw final accuracy per family and representation, overall descriptive counts, missing usage, tokens, duration, and failure classes. Denominators include scheduled failed slots; also show conditional-on-response validity when useful. With only two cases per condition, do not infer causal superiority from score differences or pool away model/representation distinctions.

Provider inference is stochastic, transport concurrency does not prove server compute concurrency, free capacity may be shared with other usage, and remote MoE performance does not establish feasibility on the user's local hardware. Independent audit reconstructs public solutions, exact compilation and envelopes, event replays, frozen hashes, and the one-send/no-paid boundaries. Follow-up iterations require a new freeze and preserve prior results.
