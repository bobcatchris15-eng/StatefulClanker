# Implementation plan and operational boundaries

1. Freeze experiment design and free routes before any campaign call. Route changes, model replacements, prompt changes, or generation-policy changes require a new campaign directory and preregistration.
2. Build the `FreeDispatch` Release package once. `prepare` copies and hashes the runtime package; call slots launch the copied DLL directly and cannot rebuild the helper.
3. Prepare with `provider_experiment.py prepare`. This is local-only: it creates eight independent Lab 4 stores, frozen route inputs, full/payload proposer prompts, payload compile contexts, and the 96-slot schedule. It does not send requests.
4. Execute conditions in the manifest order. Each of 12 role requests is fresh. Each phase prepares and freezes both requests before dispatching them concurrently. Failures consume their slots; there is no retry, correction, route fallback, resume, or semantic response check.
5. Preserve every artifact, including malformed content and transport failures. Payload compilers use only role schema, scheduled identity, known references, and pre-dispatch shared state; they do not solve the task or select the best claim.
6. Run `evaluate` only after all 96 slots have outcomes. It validates completion digests and source/input/runtime/initial-prompt freeze checks, then invokes the existing offline evaluator.
7. Have an independent reviewer inspect the frozen manifest, receipt completeness, and representative full/payload compilation before any provider run. Provider calls are excluded from unit tests.

The only runtime dependency not frozen as source is the existing production Router project: its compiled Router assembly and related runtime files are copied into the campaign dispatcher package and individually hashed. Dispatcher and adapter source files, Lab 4 `pilot.py` and `protocol.py`, the Lab 3 case generator, test source, selected catalogs, allowlists, preregistration, and initial prompts are hash-pinned. No secrets are written into this campaign.
