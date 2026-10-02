# BREADTH2 PREREGISTRATION

## Campaign Identity

**Campaign:** breadth2  
**Preregistered:** 2026-10-02  
**Protocol:** Lab 4 affine-reasoning, frozen breadth-calibration design (schema: provider-breadth-campaign-v1)  
**Inherits:** breadth1 design (4 models, kilo-free only) — breadth2 expands to 8 models across 3 providers

## Research Question

Does model scale, context capacity, architecture family, or provider diversity predict structured-payload compliance
in a fully blinded, single-turn affine-reasoning task?  
Breadth2 adds four new participants to the breadth1 cohort for a cross-family calibration.

## Participants (8 total)

### Carried Over from breadth1 (4 models)

| Key | Model ID | Provider | Context | Notes |
|-----|----------|----------|---------|-------|
| liquid | liquid/lfm-2.5-2.6b:free | Kilo Free | 32K | Liquid Neural Network baseline |
| north | cohere/north-mini-code:free | Kilo Free | 128K | Cohere command family |
| laguna | poolside/laguna-xs-2.1:free | Kilo Free | 32K | Poolside code-specialized |
| nemotron | nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free | Kilo Free | 256K | NVIDIA Nemotron reasoning |

### New in breadth2 (4 models)

| Key | Model ID | Provider | Context | Rationale |
|-----|----------|----------|---------|-----------|
| inkling | thinkingmachines/inkling:free | OpenRouter | 1M | Largest context window in cohort; tests ultra-long-context behavior at free tier |
| qwen | qwen/qwen3.8-27b:free | Kilo Free | 262K | Alibaba Qwen family; diverse training regime; strong multilingual baseline |
| gemma31b | google/gemma-4-31b-it:free | OpenRouter | 262K | Largest dense Gemma 4 free variant; Google family diversification from Gemini path |
| ultra | nvidia/nemotron-3-ultra-550b-a55b:free | Kilo Free | 1M | Largest free MoE model available; scale probe complementing nemotron nano |

### Gemini (held for breadth3)

| Key | Model ID | Provider | Context | Status |
|-----|----------|----------|---------|--------|
| gemini | gemini-3.8-flash | AI Studio | 1M | Allowlist and catalog prepared; deferred to breadth3 pending ai-studio provider integration validation |

## Design

- **Conditions per model:** 2 (`full`, `payload`)
- **Seeds:** 2 (4201, 4202)
- **Roles per seed:** 6 (u-proposer, v-proposer, u-reviewer, v-reviewer, shared-integrator, raw-integrator)
- **Total slots:** 8 × 2 × 2 × 6 = 192
- **Parallelism:** PARALLEL_PER_PHASE=2 (per condition phase)
- **Retry policy:** none — each slot executed exactly once

## Provider Configuration

| Provider | Connection ID | Base URL |
|----------|--------------|---------|
| kilo-free | Kilo Free | https://api.kilo.ai/api/gateway |
| openrouter | OpenRouter | https://openrouter.ai/api/v1 |
| ai-studio | AI Studio | https://generativelanguage.googleapis.com/v1beta |

## Catalog Attestation

- **kilo-free-catalog.json** sha256: `91b0f8dd6199ab37f6a27642ca7e70ae453dd704001c2f7eaf8a04f7da0f9167`
- **openrouter-free-catalog.json** sha256: `3bfb0f214a25f4aff6e696440f60ddce6211d0217995549e439776c008e2a0ff`
- **ai-studio-free-catalog.json** sha256: `fbd52fc26bae76fc7baa3395a26996daba4cd960381175a5259190c204bac12a`

All models confirmed zero-price or free_tier:true in their respective frozen catalogs at preregistration time.

## Evaluation Policy

Offline only. Evaluation runs after all 192 slots have outcomes (successes, quota failures, or HTTP errors all count as consumed slots).

## Stopping Rules

- Quota/HTTP failures from any provider are consumed slots — do NOT stop early.
- Infrastructure failures (nonzero exit from process error, not provider error) halt the affected condition; state is preserved.
- No condition may be resumed after an infrastructure failure; it counts as fully failed.

## Relationship to breadth1

breadth2 is an independent campaign sharing the same Lab 4 protocol and frozen harness design.
breadth1 results are not used to influence breadth2 model selection or analysis.
Both campaigns are analyzed together as a cross-family breadth calibration.
