# Free-provider research routing

Setup selection update: four responding families are Liquid, North Mini Code, Laguna XS, and Nemotron through Kilo. Original Gemma/OpenRouter candidate returned HTTP429 during readiness and was replaced before experimental freeze. Exact setup attempts and hashes are retained in setup-probes/. Earlier candidate discussion below describes the design stage.

User authority: reuse the live install's configured connectors or build a matching router, dispatch small free provider models, and keep iterating until controlled experiments run successfully with a useful breadth of results. Existing machine credentials remain machine-local. No paid inference, account purchases or live app reconfiguration is authorized by this free-model scope.

## Approach

Reuse StatefulClanker.Router's real ConnectionCredentialResolver and ProviderAdapterRegistry through a thin C# executable in this research directory. Read the installed machine connection document without copying or printing secrets. Make one exact request to a frozen allowlisted free endpoint, preserve the outgoing body and full HTTP response, and emit normalized metadata plus unchanged final content. Reuse the protocol laboratory above this transport. Leave production and installed router code/configuration unchanged.

The resident inference CLI is a useful operational router but retries some empty/truncated/tool responses internally and retains response excerpts. Those are appropriate operational features, but a one-attempt experiment needs explicit attempt budgets and complete evidence. The thin dispatcher reuses the existing transport/auth implementation while deliberately omitting automatic retries and route migration. It is not a replacement for the resident orchestration app.

## Free and scope invariants

Only exact configured OpenRouter and Kilo Free origins are initially eligible. Model IDs must be explicitly selected, end in :free, and have prompt/completion price zero in the frozen live public catalog. Unknown price, paid variant, arbitrary origin, redirect and unlisted model fail closed before sending. Each call records the connection, requested model, reported model, wire budget, actual response and usage. Router alias/free tiers that hide the model are excluded. Exhausted free capacity is an operational failure or a reason to start a separately planned run elsewhere; it never enables a paid fallback.

Machine-level target rows that were disabled stay disabled. Research selection is independent, explicitly authorized by the user, and does not change live endpoint eligibility. The dispatcher reads only selected connector profiles and resolves their credentials internally.

## Breadth and next controlled study

Target four distinct model families, subject to successful tiny setup probes: Liquid LFM2.5-2.6B, Cohere North Mini Code, Poolside Laguna XS 2.1 and Google Gemma4-26B-A4B. Distinguish the 2.6B compact model from 30–33B-total / roughly3–4B-active mixture-of-experts models; active parameter counts do not make their memory footprints equivalent to a small dense local model.

Run the same complete-facts affine tasks with fresh proposal, cross-review and shared/raw integration roles. Compare full model-authored envelopes with compact role-specific model payloads wrapped in deterministic envelopes by the runner. The wrapper supplies only known identity/routing/pinned references and schema fields, never inferred mathematics or correctness repairs. Preserve malformed outputs; count payload/schema validity separately from true-answer correctness. Rejected proposals cause genuine state attrition rather than fabricated claims.

Freeze a separate run for each model/representation condition, with exact source/model/provider/prompt hashes and a fixed twelve-slot schedule. Two cases per condition yield descriptive comparisons, not a statistical generalization or universal 50% success claim. A planned four-model/two-representation campaign has96 primary slots. Setup probes are separate; failed runs remain evidence and do not quietly receive replacement answers. Successful execution means complete audited outcomes and useful comparison coverage, not forcing a positive hypothesis result.

## Validation

Fake-network tests establish free/origin enforcement, no retries/redirects, exact evidence retention and error classification. Independently audit dispatcher source/secret boundaries before live probes. Then verify each selected free provider/model returns a tiny response. Independently test compact wrapping and offline scoring, freeze all conditions, and dispatch bounded parallel pairs. Keep quota failures separate from schema and reasoning failures. Independent final audit must recompute targets, verify all attempted/unattempted slots, content/request hashes and replay, and assess whether useful model-authored state actually reached integrators.
