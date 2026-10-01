# Skeptic source ledger

Date checked: 2026-10-01. “Primary” means the source is the study/paper itself. Forum items are anecdotal engineering discussion, not controlled evidence. Claims below are deliberately limited to the evidence described by each source.

## Scholarly and technical primary sources

1. **Schuurmans, “Memory Augmented Large Language Models are Computationally Universal” (2023), arXiv preprint.** Direct URL: https://arxiv.org/abs/2301.04589
   - Supported claim: the paper constructs an external associative read/write memory and prompt-program loop in which Flan-U-PaLM 540B simulates the universal Turing machine U15,2. It reasons formally that bounded-string deterministic LMs alone are finite-state, while unbounded external memory plus the loop allows unbounded computation. The paper verifies a finite set of prompt behaviors in a fixed construction.
   - Limitation: this is an expressivity construction, not a benchmark of useful reasoning, sample efficiency, reliable natural-language state updates, or performance of a smaller model under a native-capacity limit. It uses a 540B model and an explicit instruction/program setup. Turing completeness does not imply that a model reliably executes arbitrary programs or that the memory itself improves reasoning.

2. **Liu et al., “Lost in the Middle: How Language Models Use Long Contexts” (TACL 2024; preprint 2023).** Direct URL: https://arxiv.org/abs/2307.03172
   - Supported claim: in controlled multi-document QA and synthetic key-value retrieval, tested models’ performance often falls when relevant information is in the middle of long contexts; the authors report cases below closed-book performance and note that longer contexts can add distractors. Their GPT-4 subset also shows position sensitivity.
   - Limitation: evaluations are from 2023 models and specific tasks. This is evidence that a nominal context window need not equal robust usable capacity, not proof no model can use long states or that external memory resolves the problem. Some evaluated models performed near-perfectly on the synthetic retrieval task.

3. **Hu et al., “Evaluating Memory in LLM Agents via Incremental Multi-Turn Interactions” / MemoryAgentBench (2025 preprint; ICLR 2026 publication listed by OpenReview).** Direct URL: https://arxiv.org/abs/2507.05257
   - Supported claim: authors define four distinct memory-agent competencies—accurate retrieval, test-time learning, long-range understanding, and selective forgetting—and report current methods fall short of mastering all four. Benchmark adapts tasks to incremental multi-turn interaction.
   - Limitation: a benchmark’s selected tasks and evaluated systems do not prove all memory agents fail or that a particular external-state design will fail. QA-heavy tasks may not represent procedural reasoning; a score is not a direct test of the hypothesis’ independently measured capacity claim.

4. **Kirsh & Maglio, “On Distinguishing Epistemic from Pragmatic Action” (Cognitive Science, 1994).** Direct URL: https://doi.org/10.1207/S15516709COG1804_1
   - Supported claim: authors present Tetris observations and argument that some rotations/translations are actions that make information easier to compute, and report that a standard information-processing model does not explain observed player performance even when relaxing strict sequential processing.
   - Limitation: human, embodied, real-time Tetris; it supports the possibility and task-specific utility of epistemic actions, not LLM text-file memory, cross-session continuity, or generality across tasks.

5. **Gilbert et al., “Cognitive offloading is value-based decision making: Modelling cognitive effort and the expected value of memory” (Cognition, 2024).** Direct URL: https://doi.org/10.1016/j.cognition.2024.105783
   - Supported claim: the paper’s simulations reproduce established findings that offloading varies with value, load, and reminder reliability; offloading can lead to forgetting of offloaded items while improving memory for other items, and unreliable reminders reduce the latter benefit.
   - Limitation: this is a model of human prospective-memory decisions, not an LLM-agent experiment. Use it to motivate reliability/cost controls, not to assert equivalent effects in models.

6. **Risko & Dunn, “Storing information in-the-world: Metacognition and cognitive offloading in a short-term memory task” (2015).** Direct URL: https://pubmed.ncbi.nlm.nih.gov/26092219/
   - Supported claim: the reported study concerns people choosing to store information externally in a short-term-memory task; the abstract notes participants sometimes used external storage even where it afforded no observable benefit.
   - Limitation: the abstract alone is brief, and the task is human short-term memory, not machine reasoning. It cautions that choosing to offload is not itself evidence of task improvement.

7. **Hu et al., “AgentPoison: Red-teaming LLM Agents via Poisoning Memory or Knowledge Bases” (ICLR 2025).** Direct URL: https://openreview.net/pdf?id=707fb9874a6d1beb97c9103c8db11c3d963ee36a
   - Supported claim: authors introduce attacks that poison an agent’s long-term memory or RAG knowledge base to induce targeted behavior, demonstrating that memory-based systems can have an attack surface beyond the current prompt.
   - Limitation: adversarial attack results are conditioned on the paper’s attack and agent setup; they do not show ordinary state updates are usually corrupted, nor do they measure coherent-state reasoning utility. They justify corruption and provenance tests.

## Technical forum signal (anecdotal, not scholarly evidence)

8. **Reddit, r/AI_Agents, “Please critique my Agent Memory Benchmark Exam” (2026).** Direct URL: https://www.reddit.com/r/AI_Agents/comments/1vyp3i5/please_critique_my_agent_memory_benchmark_exam/
   - Supported claim: a practitioner describes a benchmark whose ingestion includes a scripted conversation and whose test answers are recorded from the agent’s responses. The thread surfaces a practical benchmark-design risk: if an agent generated the later answer key, its earlier phrasing/assumptions can contaminate what counts as ground truth.
   - Limitation: self-reported, unreviewed forum post; not proof that a particular system leaks answers or that the design is invalid. It is useful as a concrete engineering concern, not as a performance estimate.

## Evidence receipt

Source types reviewed: primary research papers/preprints (7), technical forum thread (1). Direct claims were checked against abstracts or source text where available. Strongest contrary/limiting evidence: (a) universality demonstrates formal possibility but not practical reasoning quality; (b) long-context retrieval is position-sensitive; (c) contemporary memory benchmarks expose multiple competencies that remain unsolved; (d) state stores create update/retrieval/corruption risks. No source found in this first wave establishes the full model-specific capacity claim either way. Confidence: moderate for the narrow claims above; low for generalizing human offloading studies to LLM agents. Temporal applicability: research results are historical and model-specific; revalidate against the actual experimental model/harness.
