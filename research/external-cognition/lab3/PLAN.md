# Agent-authored causal reasoning implementation plan

Goal: implement approved design and execute matched causal controls.
Architecture: experiment.py separates structural store, prompt construction, and offline evaluator. Native subjects create all live semantic transitions. Standard library Python, Windows supported. Spec DESIGN.md.

- [x] Engine worker writes failing meaningful tests, implements generator (three invertible mod11 worlds), enumerative evaluator, structural versioned store and safe packed codec, prompt builder and CLI; README and red/green receipt. Store must accept semantically wrong well-formed patches.
- [x] Methods worker preregisters21 calls, missing/altered scoring, attrition rules, no feedback and revision limitations; examines design for causal confounds before subjects.
- [x] Root validates CLI/tests, resolves independent pre-live findings, freezes source/tests/protocol/prompts.
- [x] Run three producers, four downstream arms per valid producer, three revision producers and consumers, fresh contexts and immutable exact outputs. Never inject evaluator answers.
- [x] Independent reviewer enumerates live outcomes, hashes, structural-only acceptance and controls; root reports limitations, updates durable state and commits scoped artifacts.

API contract owned by engine: prepare --out-dir; producer-prompt --campaign --case; submit-producer --campaign --case --response; consumer-prompts --campaign --case; submit-consumer --campaign --case --arm --response; revision-prompt --campaign --case; submit-revision --campaign --case --response; summary --campaign. Engine documents exact CLI and files. Consumer arms intact, omitted, altered, raw, revised. Only engine may modify experiment.py/tests; methods owns PREREGISTRATION.md and METHODS.md. Reviewers write audits only.

Completed21 semantic responses and independent live audit. Original frozen evaluation defect preserved; post-campaign maintenance separately recorded. Local/parallel shared-state direction continues in lab4.
