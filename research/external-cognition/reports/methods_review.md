# Methods review: does the pilot test the stated hypothesis?

**Review date:** 2026-10-01
**Question:** “Reasoning or cognition state can be represented externally, and changed incrementally and coherently to advance the reasoning by models that are not capable of holding the full representation internally.”

## Finding

The proposed pilot is a reasonable narrow test of one engineering mechanism: whether a fresh model call can use a prior call's structured, derived constraint state to apply an exclusion. It does not test whether the model is unable to hold the complete representation internally. It also cannot attribute any benefit specifically to persistent external state, because the state condition receives Phase 1's enumerated feasible selections and optimum, while the full-context control must derive those results again from source facts. This is transfer of useful computation as well as state.

## Required fixes before subject runs

1. **Create and freeze the evaluator/key.** The protocol refers to `score.py` and `private/answer_key.json`; neither currently exists. Validate evaluator behavior independently and preserve a hash/version before viewing subject outputs. Make ledger scoring reject duplicates.
2. **Repair fixture B's delta.** E is mandatory; C conflicts with E; H depends on C. H is already impossible, so making it unavailable removes no feasible candidates. Pick an initially feasible target. To test winner revision, make the delta invalidate the pre-delta winner in each puzzle.
3. **Freeze execution settings.** Record the exact model/route, decoding/sampling settings, output-token limit, tool restrictions, and call sequence. Use the same explicit values across arms and counterbalance order as predeclared.
4. **Bound and report response resources.** Candidate ledgers can be large and are the main scored output. Set a common output ceiling and report actual prompt/completion tokens and truncation. Otherwise a condition may lose points due to serialization budget.

## Interpretation and follow-up

A positive pilot result would support only: “On these two constraint puzzles, a fresh solver performed better after receiving a typed, derived candidate ledger than after receiving raw facts and recomputing.” It would not support native incapacity, general reasoning improvement, or a representation-only effect.

To address the full hypothesis later, first estimate reliable internal capacity on held-out, randomly generated tasks without externally imposed clipping. Then compare incremental external state against full-context, fact-only state, and token/call/compute-matched controls on instances below and above that preregistered threshold. Score every transition invariant separately from final-task accuracy; include shuffled or seeded-corrupt state to test whether coherent updates and provenance checks matter. Keep the current small pilot descriptive (two fixtures are not a basis for significance tests).

## Primary-source audit

- [Schuurmans (2023), computational universality](https://arxiv.org/abs/2301.04589): specific Flan-U-PaLM 540B plus an external associative memory and prompt program, verified through a finite set of behaviors; expressivity result, not practical performance/capacity evidence.
- [Hu et al. (2025 preprint), MemoryAgentBench](https://arxiv.org/abs/2507.05257): four memory-agent competencies and evaluated systems' shortcomings are reported; later version labeled ICLR 2026 ([OpenReview PDF](https://openreview.net/pdf/dca8178b2d4fb7cd70a435ed43b655c97ce9871c.pdf)). The benchmark motivates broader testing but is not evidence that all agents fail.
- [Liu et al. (2023 preprint), Lost in the Middle](https://arxiv.org/abs/2307.03172): task- and model-specific position degradation supports a long-context retrieval concern, not the pilot's capacity claim.
- [Hugging Face practitioner thread](https://discuss.huggingface.co/t/how-do-you-design-memory-systems-for-long-running-ai-agents/175584): opened April 27, 2026 (not May 3; that is a reply date). Treat advice as anecdote, without performance claims.
- [Reddit benchmark discussion](https://www.reddit.com/r/AI_Agents/comments/1vyp3i5/please_critique_my_agent_memory_benchmark_exam/): dated August 26, 2026; self-reported answer-key workflow raises a possible estimand/comparability issue, not proof of invalid scoring.
