# Worker model selection

Pi owns connections, auth, and model metadata. StatefulClanker adds capability
profiles, selection, cross-worker health, and leasing. Inference never routes
through us.

## Candidate pool
- Start from `ctx.modelRegistry.getAvailable()`. These are models whose provider auth is configured.
- If `ctx.scopedModels` is non-empty (from `enabledModels` or `--models`), intersect with it.
- Key each model as `provider/id`.
- The pool is exactly Pi's available models, scoped by `enabledModels`/`--models`. Nothing else is filtered here (health and leases are handled in select).
- Workers get the parent's `-e`/`--extension` paths forwarded, so extension-registered providers work. Global and settings-listed extensions load automatically in workers. `PI_CODING_AGENT_DIR` is passed explicitly and recorded, with the extension paths, in the spawn receipt.

## Profile layers
Each layer overrides the one before it.

1. **Derived from the Pi `Model`:**
   - `vision` from `input` including `image`
   - `long_context` from `contextWindow`
   - `free` when every `cost` field is zero
   - a `reasoning` hint from `reasoning`
2. **Curated (machine):** `%LOCALAPPDATA%/StatefulClanker/profiles.json`. Entries are keyed by glob pattern and hold qualitative ratings (`unknown|poor|fair|good|excellent`) and quirks.
3. **Curated (project):** `.statefulclanker/profiles.json`, same shape. It overrides the machine layer.
4. **Observed:** `%LOCALAPPDATA%/StatefulClanker/observations.jsonl`, aggregated per model and task class. Observed data dominates once it has at least `minSamples` samples. Below that it only nudges.

A model with no data at any layer is `unknown`. It is eligible but ranks below rated models.

## Ability profiles
The presets are `implementation`, `research`, `architecture`, `review`, and `fast`. Each one defines minimums and weights per capability. Ad-hoc requirements are accepted.

## Selection
`select(request, candidates, state)` is a pure function.

1. **Hard filters:**
   - every minimum is met (unknown passes)
   - `tool_use` is not `poor`
   - `contextWindow` is at least what the task needs
   - the model is not in cooldown
   - a lease slot is free
   - `free_only` and the avoid/prefer lists are respected
2. **Suitability:** a weighted score against the profile.
3. **Diversity:** only candidates within ε of the top suitability score can be reordered. Candidates that share a provider or family with `diversity_from`, or with the worker under review, take a penalty.
4. **Output:** the chosen model, `selection_reason`, the ranked runner-ups, and the reason each filtered model was excluded. All of it is written to a spawn receipt.

## No inheritance
- The worker's `model` is optional and selection runs when it is absent.
- The parent's `ctx.model` is just another candidate, and it takes the diversity penalty for independent spawns.
- An explicit model is still checked against the registry, auth, health, and lease.
- Workers always get explicit `--provider`, `--model`, and `--thinking`.
- When no candidate fits, the result is an error listing why each model was filtered out. It never falls back silently.

## Health and leases (machine-wide)
- **Health:** each model tracks `failure_streak` and `cooldown_until`.
  - Rate-limit, auth, and exhausted-retry signals from worker RPC events trigger a cooldown with exponential backoff.
  - A success resets the streak.
- **Leases:**
  - Leases live in `%LOCALAPPDATA%/StatefulClanker/leases.json`, guarded by an O_EXCL lockfile.
  - The owner is the worker id plus the parent PID, and each lease has a TTL.
  - Capacity defaults to 1 for free models and unlimited for paid ones. Profiles can override it.
  - Leases are released on worker exit, cancel, and retire. Leases held by a dead PID are reclaimed.
