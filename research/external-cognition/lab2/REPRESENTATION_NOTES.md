# Representation research notes: what may be opaque, and what reaches the model

Date: 2026-10-01

## Position

The state does not have to be human-readable. It must still be clear which component owns it, which component reads it, what information the model actually receives, and how correctness is independently checked. “Opaque to a person” is a storage/inspection choice; “continuous latent thought” is a model-architecture/training mechanism. They should not be treated as synonyms.

## Three distinct representation paths

1. **Opaque serialized machine state.** The host can store a versioned, compressed/checksummed binary frontier and decode it when needed. This is useful even if no person inspects the bytes. If the host decodes it and places the recovered frontier in a prompt, then the subject receives the decoded representation, not the opaque byte stream. If the subject never receives it, a codec change tests persistence, size, integrity, and recovery—not cognition or representation. Base64 is merely a reversible textual encoding of bytes; absent an agreed grammar/decoder, it does not become a learned state just because a text model sees its characters.

2. **External model-consumable representations.** A host can expose a compact schema, tuples, bit-packed symbols, sparse coordinates, or graph identifiers through a text API. It may be unreadable to people while still being usable by a model if the prompt establishes the codebook and the model can manipulate the values. But a JSON/CSV numeric vector sent as text is tokenized text, not a continuous vector injected into the model’s embedding stream. The model must infer/use the stated code, and performance is an empirical question. An uninterpretable random coordinate array is unlikely to help a text-only model without a learned decoder or direct numerical operations. Likewise, a graph memory helps only if the host or the prompt gives the model a path to traverse its nodes/edges; a graph hidden in a file is only storage.

3. **Neural hidden state / learned continuous thought.** Coconut explicitly takes the model’s final hidden state and feeds it back as the next input embedding; this runs inside the model’s forward pass and is trained end-to-end with a curriculum. Recurrent-depth models similarly iterate a trained recurrent block at inference. These systems require backend access to hidden tensors/input embeddings and model training or architecture support. They are not replicated by writing floats to a file, emitting numeric text, using ordinary conversation continuation, or adding a tool to a native agent. Published results are demonstrations on specific trained models/tasks, not evidence that a hosted text endpoint accepts arbitrary hidden activations or that latent thoughts are inherently superior.

## What literature supports—and does not

- Coconut’s mechanism is specifically hidden-state-to-input-embedding feedback, with differentiable training. Its paper reports task-specific gains (notably search-heavy logical reasoning), but its experiments use a pretrained GPT-2 trained through staged supervision; this does not establish a drop-in mechanism for a frozen hosted model. [Hao et al., *Training Large Language Models to Reason in a Continuous Latent Space*](https://arxiv.org/abs/2412.06769) (see method and training sections).
- Recurrent-depth work scales test-time compute by iterating a recurrent block. The authors report results for their trained 3.5B-parameter model; that requires architecture-level inference, and does not show that external encoded payloads act as latent thoughts. [Geiping et al., *Scaling up Test-Time Compute with Latent Reasoning: A Recurrent Depth Approach*](https://arxiv.org/abs/2502.05171).
- Recurrent Memory Transformer uses learned memory tokens carried between segments. This is a relevant precedent for continuous state across calls/segments, but it is still an architecture that trains the model to read and write the memory tokens; it is not an arbitrary external embedding accepted by any API. [Bulatov et al., *Recurrent Memory Transformer*](https://arxiv.org/abs/2207.06881).
- Graph of Thoughts makes the graph explicit in an orchestrator over LLM-generated thought units and operations. It supports graph-shaped external control/state as a workable system design, not nonlinguistic neural latent state. [Besta et al., *Graph of Thoughts: Solving Elaborate Problems with Large Language Models*](https://arxiv.org/abs/2308.09687).
- The current OpenAI text-generation guide demonstrates direct Responses API requests with string `input` and message content. That supports the conservative boundary for this lab’s native text route: send a compact textual code/schema, not arbitrary embedding tensors. It is not a claim about every private/internal API or self-hosted backend. [OpenAI API: Text generation](https://developers.openai.com/api/docs/guides/text).

## Recommended next adapter for this lab

Keep the packed codec solely as durable host storage. Add one **text-API adapter ablation** that decodes to a compact, explicitly specified, non-prose frontier grammar—for example a fixed-order tuple stream encoding `(boundary, cumulative_cost, witness_bits)` with a schema/version header—and accepts a compact tuple stream under the existing exact parser. Retain the record/JSON arm as a control. For a more “vector-like” presentation, map each frontier row to fixed-position numeric coordinates but publish the coordinate meanings and preserve a lossless round-trip; call it a numeric textual representation, not a latent embedding. Hold backing codec, task, prompts, call budget, verification, and response parser fixed; compare only the exposed schema and log exact prompt/response bytes/tokens if available. The existing task is so small that this tests interface robustness and task performance, not a generic cognitive advantage.

If later work genuinely targets latent state, use a local/open model or backend that exposes `inputs_embeds`/hidden states and can be fine-tuned. Treat that as a separate study with training, architecture, and compute controls. Do not describe a native agent tool as exposing activations unless its documented interface actually does.

## Interpretation guardrails

- Opaque packed bytes may be ideal for storage and can remain uninspectable by humans; that alone says nothing about the model’s reasoning.
- If the model receives a decoded/compact textual view, the experimental representation is that view. Do not attribute an effect to invisible on-disk bytes.
- If a host tool decodes or computes a state before exposing it, that host operation is part of the reasoning system; instrument and report it.
- Keep machine correctness (codec and parser), proposal correctness (model’s submitted next frontier), and final task correctness separate. Independent oracle/checker remains necessary even if the state is opaque.

