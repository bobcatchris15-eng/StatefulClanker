# Formal analyst source ledger

Date checked: 2026-10-01

## Primary technical sources

### Schuurmans (2023), “Memory Augmented Large Language Models are Computationally Universal”

URL: https://arxiv.org/abs/2301.04589

Primary-source type: author preprint / research paper.

**Verified from abstract:** The paper reports exact simulation of a universal Turing machine `U_{15,2}` by Flan-U-PaLM 540B combined with associative read/write memory, using a prompt-designed stored-instruction-computer setup and no weight modification. It notes that a bounded-string deterministic LM by itself is equivalent to a finite automaton.

**Interpretation:** External read/write state can change the coupled system's computational model and permit a larger evolving representation. This is an existence/construction result, not evidence of natural-language task accuracy, efficiency, error correction, or native model insufficiency on practical tasks.

Applicability: current as a theoretical result; the particular model/API setup is historical and should not be assumed available.

### Schuurmans, Dai, Zanini (2024), “Autoregressive Large Language Models are Computationally Universal”

URL: https://arxiv.org/abs/2410.03170

Primary-source type: author preprint / research paper.

**Verified from abstract:** The authors construct universal computation via extended autoregressive decoding, associate decoding with a Lag system, and report a prompt-driven Gemini 1.5 Pro experiment applying 2,027 production rules under greedy decoding.

**Interpretation:** Further computability evidence, but the extended decoding protocol is distinct from independent fresh calls sharing a file/store. Universal computability says nothing by itself about practical efficiency or robust semantic reasoning.

Applicability: current theoretical result; named API/model configuration historical.

### Acar, Ahmed, Blume, “Imperative Self-Adjusting Computation” (2007)

URL: https://newtraell.cs.uchicago.edu/research/publications/techreports/TR-2007-17

Primary-source type: University of Chicago technical report/paper record.

**Verified from abstract:** The work records dependencies through modifiable references and computation traces, then uses change propagation to update after input changes; it extends an earlier approach to support multiple writes to modifiable references.

**Interpretation:** Coherent incremental update can be engineered by explicit dependency tracking and change propagation. This validates a software mechanism, not model-generated reasoning traces.

Applicability: general programming/computation framework; current as a principle, details are historical.

### Acar et al., “A Library for Self-Adjusting Computation”

URL: https://www.sciencedirect.com/science/article/pii/S1571066106001290

DOI: https://doi.org/10.1016/j.entcs.2005.11.043

Primary-source type: peer-reviewed paper (Electronic Notes in Theoretical Computer Science, 2006).

**Verified from abstract:** Presents an SML library using modifiable references and memoization for updates; applies it to dynamic convex hull; reports small overhead and, for small changes, updates up to three orders of magnitude faster than recomputation in their experiments. The abstract notes interface scalability limitations and invariants relevant to safety.

**Interpretation:** Incrementalization may save work when change is small and dependencies are managed; it does not remove computation cost universally and can carry design/maintenance overhead.

Applicability: specific implementation and application results historical; underlying idea current.

### Hutchins (1995), *Cognition in the Wild*

URL: https://direct.mit.edu/books/monograph/4892/Cognition-in-the-Wild

Author's page: https://pages.ucsd.edu/~ehutchins/citw.html

Primary-source type: scholarly monograph, MIT Press.

**Verified from publisher/author descriptions:** Hutchins analyzes ship navigation as computation distributed across a bridge team and artifacts, including how activity is distributed through time using precomputed partial results and procedures.

**Interpretation:** Supports analyzing human cognitive work at the system level rather than assigning every operation to one head. It is not a controlled LLM study and gives no model-specific correctness guarantee.

Applicability: conceptual framework; empirical setting is historical.

## Exact claims versus inference

- **Reported fact:** A particular LM-plus-memory construction can simulate a UTM under its designed conditions.
- **Reported fact:** Self-adjusting computation systems explicitly represent dependencies and update affected outputs after input changes.
- **Inference:** A model worker can participate in a larger computation whose total external state exceeds one call's view, if interfaces allow retrieving sufficient dependencies and a protocol maintains valid state.
- **Inference:** Coherence is a property of the composed transition system and checks, not a synonym for storing a transcript.
- **Unknown from these sources:** Whether a modern model gains robust novel-task reasoning from externalized state when calls, tokens, and tools are matched; whether gains occur specifically beyond an independently measured native-capacity threshold.

## Small example provenance

The 10,000-bit parity/block ledger in `../blackboard/formal_analyst.md` is an original illustrative construction, not a reported experiment. Each block parity is independently recomputable; XOR composition forms a binary dependency tree; changing a bit invalidates one block and its ancestors. This is a deterministic checkable illustration of bounded views over larger global state, not evidence of language-model reasoning quality.
