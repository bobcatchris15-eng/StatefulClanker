# Provider breadth experiment runner

`provider_experiment.py` prepares and runs the preregistered 4-model × 2-representation × 2-case × 6-role campaign. It never calls a provider during `prepare` or `evaluate`. `run-condition` dispatches only the next complete condition in fixed order and uses one fresh request per role, two concurrent requests per phase, 4096 output tokens, temperature 0.6, a 180-second request timeout, and no retry or fallback. A partial condition is retained and cannot be resumed; preserve it and prepare a new campaign if another run is needed.

## Freeze and dispatch

Build `FreeDispatch` in Release before preparation. The campaign copies the dispatcher runtime package, selected frozen allowlists and their hashed public catalogs, preregistration, source hashes (including the Lab 4 generator/protocol and experiment runner), each condition's separate Lab 4 pilot store, and initial prompts. It records runtime SDK identity and hashes the built dispatcher and Router assemblies. The production Router source is not copied into the campaign; its compiled dependency is pinned by the captured assembly hash. Every initial prompt is cross-checked against the campaign manifest before dispatch. Dynamic prompts, their prompt hashes, payload compile contexts, and exact normalized requests are saved before the role request is sent.

The helper receives only an exact allowlist route selected before freeze. The selection map must contain `liquid`, `north`, `laguna`, and `nemotron`; each entry has an `allowlist` path and an explicit `allowed_returned_models` list. The requested `:free` model identifier is included automatically; extra aliases must be explicitly listed based on setup evidence. Provider origins are fixed to the exact OpenRouter or Kilo Free origin and catalog validation requires zero prices (and `isFree: true` for Kilo).

Example from the repository root (use a new output directory):

```powershell
python research/external-cognition/router/provider_experiment.py prepare `
  --campaign-dir research/external-cognition/router/campaigns/provider-breadth-01 `
  --allowlist-map research/external-cognition/router/allowlist-map.json `
  --preregistration research/external-cognition/router/PROVIDER_PREREGISTRATION.md
```

Then run conditions in this exact sequence. Each command attempts 12 scheduled calls and preserves failures as consumed outcomes:

```powershell
$runner = 'research/external-cognition/router/provider_experiment.py'
$campaign = 'research/external-cognition/router/campaigns/provider-breadth-01'
foreach ($model in @('liquid', 'north', 'laguna', 'nemotron')) {
  foreach ($condition in @('full', 'payload')) {
    python $runner run-condition --campaign-dir $campaign --model-key $model --condition $condition
  }
}
```

A nonzero process result or missing condition marker does not authorize rerun. Inspect the saved condition and transport receipts; the runner rejects a restart after any partial attempt. It accepts no model or provider override after freeze.

## Representations and artifacts

The `full` arm asks for the native Lab 4 envelope. The `payload` arm asks for only the role's registered compact JSON fields. A strict parser rejects duplicate keys, unhashable or unsupported field values, booleans/floats where integers are required, unknown fields, and out-of-range residues. Exact assistant content is saved before parsing. Valid payloads are compiled deterministically to protocol envelopes, with separate raw and compiled hashes. The compiler uses the role-specific peer read context frozen before dispatch; it does not refresh state after model output arrives. Invalid payloads are submitted unchanged to the structural protocol path. Transport failures consume the slot and receive a null-validity payload receipt without fabricated content.

Each condition contains its own `pilot/` store. Under `transport/<seed>/<role>/`, the helper records the exact request and response bodies, safe transport metadata, receipt, and `content.raw` on successful parse. The runner additionally retains the request, request metadata, exact assistant content, launcher output, slot result, and failure details. No credentials or authorization values are copied into experiment artifacts. `campaign.json` pins source, input, runtime, target aliases, schedule, settings, and hashes. Completion records bind each condition's 12 slot results to a digest.

After all eight conditions complete, score offline:

```powershell
python research/external-cognition/router/provider_experiment.py evaluate `
  --campaign-dir research/external-cognition/router/campaigns/provider-breadth-01
```

Evaluation validates frozen identities and all per-condition completion digests, then calls the existing Lab 4 offline evaluator. It makes no network or router calls. The result is descriptive for two cases per model/representation and should not be interpreted as a broad success-rate or causal superiority estimate.

Tests use fake dispatchers and temporary directories only; they do not send inference requests:

```powershell
python -m unittest discover -s research/external-cognition/router/tests -v
```
