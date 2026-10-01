# Final methods review: post-run evidence and limits

**Date:** 2026-10-01
**Scope:** independent post-run review of the external-state pilot v1.1 and bounded-view CSP chain. I did not modify prompts, outputs, scorers, fixtures, or production files.

## What the pilot actually shows

Independent exhaustive enumeration of all subsets confirms the key: A has 19 feasible selections before and 14 after project G becomes unavailable; B has 10 before and 6 after project D becomes unavailable. The before/after winners also match the key: A changes from AEFGH (cost 10, value 27) to CEFH (cost 9, value 23); B changes from DEFG (cost 9, value 26) to ABEG (cost 7, value 22). The scorer's self-check passes.

The frozen scorer reports Phase 2 scores of 90 and 90 for state, and 90 and 80 for full-context control, for descriptive means of 90 versus 85. All four conditions have the exact post-delta candidate ledger and exact winner by independent enumeration. The five-point composite difference comes from how availability and removed candidates are serialized, not a difference in solution accuracy. In all four responses the delta is represented correctly, and the listed removed selections are semantically the right set.

The protocol does not specify a representation for unavailable projects inside `current_state.source_facts`; it requires a `changed_facts` item with an `availability` field, while the scorer requires an `unavailable` array. Both B subjects used an `availability` mapping, so both lose the source-fact component despite recording D's unavailability. The protocol also says `removed_candidates` lists old selections without defining the element schema. Three outputs use full candidate rows and one uses ID arrays; the scorer only accepts ID arrays. This costs points for semantically correct removed sets. These schema ambiguities mean the 90-versus-85 difference is not evidence of a state-condition advantage. Preserve the registered score, but report exact ledgers/winners as 4/4 and separately describe the schema issue.

The control also had one process deviation: A-control Phase 2 reread the prompt and corrected its draft before submitting the saved answer; the original draft was not retained. This is logged in `execution_log.md`. Exact token counts and sampler limits were unavailable, so resource equality cannot be assessed. All subjects had a procedural 20,000-character ceiling; response files ranged from 1,680 to 2,783 bytes. These byte counts are not token counts.

## Bounded-view chain result

I independently reran the stage checker. Stage 1 is accepted. Stage 2 is rejected: its E=1 row uses C=1,D=0,E=1, which sums to 2 and violates the frozen odd-parity constraint; its reported cumulative cost 1 omits E's cost of 3. The correct E=1 frontier row is cost 3 with witness A=0,B=0,C=0,D=0,E=1. Stage 3 is rejected because the prior state was rejected; its proposed assignment also violates the stage-2 parity constraint and its cost 2 is incorrect. Independent enumeration gives global optimum cost 4 at A=0,B=0,C=0,D=0,E=1,F=0,G=1. This chain shows a correct initial frontier, then a failed update, then propagation of invalid state.

The bounded-view evaluator checks the passed prior response and prints a policy to preserve prior accepted state. It does not implement a durable transactional store or actually commit/rollback state. The human coordinator manually passed the raw response forward, and the next stage was rejected. Describe this as prompt-mediated handoff plus external validation, not an implemented transactional memory system. Its slice restriction was imposed, so it says nothing about native capacity.

## Freeze receipts

SHA-256 hashes and byte lengths below are post-run audit receipts for the preserved raw response files. They supplement the pre-run freeze manifest; they are not pre-registration hashes.

| Output | Bytes | SHA-256 |
|---|---:|---|
| `a_state_phase1.json` | 2,182 | `fe2072ef4f96443ace56c183cba392b0894bea794210abd07045a48c6d9b5dd9` |
| `a_state_phase2.json` | 2,783 | `4e91ccaa09aa97725842c03d5d6a7f60aef6ea582660f8133f2df4bda6263d5d` |
| `a_control_phase1.json` | 2,048 | `1d612975072857f6f6c72613ae9eef159cb83768cc28a7db7e33d84c7a08ebbd` |
| `a_control_phase2.json` | 2,729 | `770ed42cbde3d30232b908532a6bc7a8eff23f916b4c8a578b565f78789201f1` |
| `b_state_phase1.json` | 1,687 | `8d22a3dc212da6f33effb30ab8c9a3b5446118d765a8563440403cf6ac8fe11f` |
| `b_state_phase2.json` | 2,181 | `eb163aaae42c29f2024e1256c7ad2f82d9db8086acc46a27301127e95c45a082` |
| `b_control_phase1.json` | 1,680 | `f209dc21895f48e5d7fd1865f010188fa5e5d2663a3ef39cc113856b0b3e6b7e` |
| `b_control_phase2.json` | 2,260 | `688109f4e00e631fe5045d0b825ae5a023b3e6cd6b4278dd32c7b5f3e10426af` |
| bounded `response_1.json` | 187 | `ead2e6563910ef3bd1506451ebf29cbe829661b3725cc27d9cd457fbff87ed3b` |
| bounded `response_2.json` | 309 | `f526048b2e285892483d13cf0004eaf0c61ef37e735654c6e19566de46f77e4a` |
| bounded `response_3.json` | 271 | `1367372fd74a7d67f503fd2c4ea021876b4694c5a29c7937b1e012299e62a3b2` |

## Relevance to the exact hypothesis

The pilot offers narrow descriptive evidence about handing a derived candidate ledger to a fresh call versus recomputing from facts. It did not manipulate or independently measure a native capacity threshold, and state carries answer-bearing search work. The bounded-view chain used imposed slices and failed at the first state transition. Neither experiment establishes that external cognition lets a model that cannot internally hold the full representation advance reasoning more effectively. At most, the pilot's four correct Phase 2 ledgers/winners show that fresh calls can use supplied task state on these two small puzzles; the bounded-view chain shows that incorrect state can propagate unless an external validator rejects it.

## Source validity and limits

The first-pass audit remains applicable: [Schuurmans (2023)](https://arxiv.org/abs/2301.04589) proves computational universality for a specific Flan-U-PaLM 540B plus memory and a carefully programmed loop, not generic task utility. [MemoryAgentBench](https://arxiv.org/abs/2507.05257) defines four memory competencies and reports weaknesses in evaluated methods; its primary preprint is from 2025 and the later version is labeled ICLR 2026. [Lost in the Middle](https://arxiv.org/abs/2307.03172) reports model/task-specific positional effects. The [Hugging Face forum thread](https://discuss.huggingface.co/t/how-do-you-design-memory-systems-for-long-running-ai-agents/175584) opened April 27, 2026; its May 3 reply date was previously misreported as the thread start. Forum statements remain practitioner anecdotes, not controlled performance evidence.

## Adaptive recovery follow-up

The separate recovery protocol launched two new fresh subjects after the rejected original Stage 2. I reran the unchanged checker against `repair_response2.json` and `repair_response3.json`: both are rejected. Recovery Stage 2's E=0 row uses a non-minimal witness and incorrect cost (reports 3; exact row is A0/B0/C0/D1/E0, cost 1). Its E=1 row is parity-invalid (C1+D0+E1=2, where odd is required) and understates cost (reports 1; exact row cost is 3). Stage 3 repeats the invalid cost-2 answer, and the preceding rejection invalidates the chain. The correct global optimum remains cost 4 at A0/B0/C0/D0/E1/F0/G1.

This is one adaptive feedback-assisted recovery chain, separate from the original fixed pilot; it is not pooled as confirmatory evidence. It did not repair the transition. The total fresh subject count is 13. The synthesis heading currently says recovery is pending and should be updated to record both rejections and this count. The synthesis's narrower substantive conclusions remain sound.
