# External cognition research: successor instruction manual

Handoff written for the user's October 2, 2026 client date, America/Chicago. Historical transport timestamps and registrations retain their original dates. Read this first. This manual supersedes older active/pending entries in the chronological state files.

## The user's objective and authority

Continue building and testing distributed reasoning engines in which smaller models access a large problem in parallel, communicate through structured deterministic envelopes, and incrementally maintain coherent external reasoning state. The original hypothesis is that models unable to hold a full representation internally might still advance reasoning through an external representation. The refined framing is **fresh reasoning produced by native reasoning**, not merely extending a model's private chain of thought.

The representation need not be human-inspectable. Standardized, repeatable state and communication are more important than prose readability. Accuracy superiority is not required: matching controls or useful partial performance can enable cooperative engines. The user's illustrative 50% is not a universal acceptance threshold; define task, denominator, resources, and threshold before a run. A proposal based on changed premises should remain a **potential fork**, not be discarded automatically. It may be archived after an explicit evidence-backed judgment that the prevailing state is workable; retain its history.

User authorized autonomous research, debate, implementation, experiments on fresh subjects, and continued iteration until completed controlled runs give useful breadth. Up to five research specialists plus experimental subjects were allowed. Native host concurrency has been four including root, so use at most three simultaneous workers here. The requested Luna Light route is not exposed; previous work disclosed and used `gpt-6-luna` with low effort. New workers with an explicit model override need a bounded context fork, not a full-history fork.

User also authorized testing local Qwen through Lemonade and adjusting its settings if needed, then explicitly asked to reuse the installed Clanker router/configured connectors or build a matching router to use small **free** provider models. Authorization persists; do not ask again to perform these reversible research actions. No paid inference, purchases, external posting/messaging, or production deployment is authorized. The newest request was to write this full handoff because quota is nearly exhausted. All three active native workers then reported usage-limit failures. Do not assume they are still working or a scheduler will resume them.

## Workspace and preservation rules

Repository: `C:\Users\chris\StatefulClanker`; shell PowerShell; research root `research/external-cognition`. Keep research changes here. Preserve unrelated untracked `.superpowers/` and `docs/superpowers/plans/2026-09-30-router-repair.md`. Stage/commit only explicitly selected research paths. No production source, live connection configuration, enabled endpoint flags, installed app, daemon, or routing health changes are needed.

Use the Clanker Mode skill at `C:/Users/chris/.agents/skills/clanker-mode/SKILL.md` and its normative references. It has already been applied in this session, along with brainstorming, orchestration, TDD, debugging, and verification. Existing user authorization covers implementation choices; do not invent another approval gate. Durable state lives in this directory and bounded worker files, not remembered transcripts. There is no root graphify graph; source maps and AST/document relationships were used instead of installing another system. Do not create a new scheduler or user-owned chat just to continue this work.

Machine credentials are current-user DPAPI/env secrets. Never copy connection files into research, reveal key values, or persist Authorization header values. Existing resolver handles them in memory. Direct research output paths must be outside the live router root and not junctions/symlinks: the dispatcher's containment guard is lexical. Relevant workspace/research/setup paths were checked and are ordinary directories.

## Exact stopping point

**No controlled remote experimental requests have been dispatched.** There were eight separate readiness sends only. The affine breadth campaign already exists at:

`research/external-cognition/router/runs/breadth1`

Its canonical manifest hash is:

`bd97d69c9e8b4cf5ddf18aa50c7cf5db6254b0ff8c24b08a0394efe52c19800c`

It contains 96 planned slots, eight isolated conditions, frozen sources/inputs/runtime package, public cases, initial prompts, and initial payload compile contexts. At handoff, `_load_campaign` verified current source/input/package/initial prompt identities, with **zero condition_started markers and zero slot outcomes**. The campaign remains ready for its first dispatch. Do not prepare over this directory or rebuild/modify its frozen code. A new date does not itself invalidate the freeze; recheck free availability and unchanged source assumptions without altering its selected models. Any changed target/settings/code requires a separately named freeze.

Both independent prelive audits are present and clear:

- `router/PRELIVE_AUDIT.md`: dispatcher-only guards and one-send/raw-evidence accounting; independently passed 9 focused checks. Final implementation worker subsequently reported 11 fake-handler checks passing.
- `router/HARNESS_PRELIVE_AUDIT.md`: campaign harness cleared after fresh freeze; independently passed 11 tests in 74.9 seconds, plus a separate fake-dispatch equivalence/reference probe. Worker suite also passed 11 tests in 75.852 seconds.

The audit landed immediately before quota interruption. Its clearance is real even though the validator's final turn later ended with a quota error. The current campaign freeze was checked against the final on-disk source after that audit. Read the actual audit, not just an agent status.

Lab 5 is **partial implementation, not ready for live use**. Files currently present: DESIGN.md, PREREGISTRATION.md, generate_cases.py, pilot.py, six public cases, and private/case-key.json. No offline_evaluate.py, test suite, readiness receipt, final audit, or live run was present at inspection. Finish and independently verify it before dispatch.

## Existing results and checkpoints

- Cycle 1: commit `0676daa`, 13 native subjects; no accuracy advantage, bounded chain failed.
- Lab 2: `88f7003`, 22 native subjects; packed/JSON state, patches and dependencies; 30 tests passed, one skipped. Online semantic checker was coupled to the system, so this was not a capacity demonstration.
- Lab 3: interruption `97391d6`, completion `78b94b0`; 21 outputs from 23 dispatches including two no-output quota failures. Mixed relation/revision results. Original evaluator defect retained alongside independently corrected results/runtime. Read lab3/RESULTS.md.
- Native Lab 4: `6a0e3a3`, audit supplement `c20813e`; 12 fresh Luna-low outputs. All envelopes accepted; initial proposals 2/4 correct; reviews caught both wrong relations and supported both correct ones. Shared finals 2/2, raw-facts controls 2/2. No accuracy advantage or proven dependence on shared contributions. Read lab4/RESULTS.md and RESULTS_AUDIT.md.
- Local Qwen work: commit `c1e9ef1`. Local-qwen1 interrupted on user direction; no score. Local-qwen2 completed all 12 outcomes in about 8m6s at 512 output tokens: 11 HTTP200, one HTTP500 runlist failure; seven accepted envelopes, four invalid JSON; all four final answers wrong, shared 0/2 and raw 0/2. No valid relation proposal committed. Read lab4/LOCAL_RESULTS.md and LOCAL_RESULTS_AUDIT.md. These failures do not establish that the user's hardware or all local models are incapable.

Local runtime was Qwen `qwen3.5-9b-FLM`, reported checkpoint `qwen3.5:9b`, FLM/NPU, Lemonade 11.9.0, context 70,728, API `http://127.0.0.1:13305/api/v1/chat/completions`. The user enlarged context; coordinator made no Lemonade settings changes. Tiny local READY/JSON/concurrent-label probes succeeded. Their timings did not establish parallel hardware execution. Original 4096-token local attempts timed out; the budget hypothesis is not a demonstrated root cause. Exact artifacts and interrupted outcomes remain preserved.

## Router implementation and selected free models

The resident router's exact-endpoint API may retry internally and only returns response excerpts, so it was unsuitable for one-attempt/full-evidence controls. Research-only `router/FreeDispatch` instead references the existing .NET8 Router project and reuses `ConnectionCredentialResolver`, `ProviderAdapterRegistry`, and the OpenAI Chat adapter. It loads the live profiles read-only, resolves credentials internally, makes one HTTP send with redirects disabled and a deadline covering headers/body, and preserves full raw requests/responses and exact extracted assistant content. It neither invokes the resident routing gateway nor updates its health state.

Live profiles are under `%LOCALAPPDATA%\StatefulClanker`; exact connection dictionary IDs are `Kilo Free` and `OpenRouter`. Synthetic `research-*` endpoint IDs are recording labels, not enabled live endpoints. Current selected campaign routes are all Kilo:

| Key | Exact model ID | Size interpretation |
| --- | --- | --- |
| liquid | liquid/lfm-2.5-2.6b:free | 2.6B dense |
| north | cohere/north-mini-code:free | about 30B total, 3B active MoE |
| laguna | poolside/laguna-xs-2.1:free | about 33B total, 3B active MoE |
| nemotron | nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free | about 30B total, 3B active MoE |

Do not equate active MoE size with local weight-memory requirements. Frozen public catalogs are router/kilo-free-catalog.json and openrouter-free-catalog.json. Each selected model must have exact `:free` ID and zero prompt/completion prices; Kilo also requires `isFree: true`. Allowlist catalog hashes and exact origin are checked before secrets. No generic automatic free route, paid fallback, or silently substituted model is allowed. Source allowlists are in router/allowlists; selected aliases in allowlist-map.json. Four selected returned IDs exactly matched requested IDs during readiness.

Setup evidence is in router/setup-probes. First 64-token Liquid/North/Laguna probes returned HTTP200 with length finishes, reasoning fields, and empty answer content. New, separately retained 512-token probes returned exact ready JSON for all three. Original Gemma/OpenRouter candidate returned HTTP429 and was replaced **before** experimental freeze by Nemotron/Kilo, whose 512-token readiness succeeded. Eight total sends: seven Kilo, one OpenRouter. They are excluded from accuracy and none had internal retries. Do not mistake new recorded setup checks for retries inside an experimental slot.

At discovery, primary Kilo docs described anonymous free access and 200 requests/hour/IP; OpenRouter free-plan documentation described 50 free requests/day. Existing usage on the same IP/account may consume capacity. Reverify current rules if needed; do not buy capacity. Useful sources: https://kilo.ai/docs/gateway/usage-and-billing, https://kilo.ai/docs/gateway/authentication, https://openrouter.ai/pricing/. Already configured Kilo anonymous access actually worked. Other connectors were not selected because zero-cost/overage boundaries were less clear.

The frozen campaign contains seven runtime files (dispatcher/Router DLLs and dependency/runtime JSON plus ProtectedData DLL), copied from a successful Release build with zero warnings/errors. No per-call `dotnet run` rebuild occurs. Production Router source is not copied into the campaign; its compiled assembly is pinned by hash. The older setup probes have their own fixed Debug package/hashes. Never rebuild those artifacts in place.

## Execute the frozen 96-slot campaign

First inspect the two audits, preregistration, README_EXPERIMENT.md, campaign.json, git status, and whether any conditions have started since this manual. Confirm free rules/selected routes remain acceptable. No fresh setup probe is automatically needed if existing evidence remains applicable; any new probe is separately recorded. Never run evaluation before all 96 outcomes exist or send semantic feedback to participants.

The fixed order is Liquid full, Liquid payload, North full, North payload, Laguna full, Laguna payload, Nemotron full, Nemotron payload. Each condition has two seeds (4201,4202), six fresh roles per seed, two concurrent requests per phase: u/v proposals, cross-reviews, shared/raw integrators. Every role gets the full public problem; only shared integration gets actual accepted peer contributions. Settings: 4096 requested output tokens, temperature 0.6, timeout 180 seconds, one fresh user message, no retries/repair/fallback. The manifest encodes temperature as a decimal string for deterministic canonicalization; the request uses numeric temperature.

From the repository root, run one condition and inspect infrastructure receipts before proceeding. Do not inspect correctness or select replacements midway:

```powershell
$runner = 'research/external-cognition/router/provider_experiment.py'
$campaign = 'research/external-cognition/router/runs/breadth1'
python $runner run-condition --campaign-dir $campaign --model-key liquid --condition full
```

For remaining conditions, use the same command with the next model/condition. The runner enforces order and rejects repeating a started condition. A simple loop is acceptable **only from a wholly unstarted campaign**, with immediate stop on nonzero exit:

```powershell
foreach ($model in @('liquid','north','laguna','nemotron')) {
  foreach ($arm in @('full','payload')) {
    python $runner run-condition --campaign-dir $campaign --model-key $model --condition $arm
    if ($LASTEXITCODE -ne 0) { throw "Stopped: $model/$arm; inspect retained state, do not retry" }
  }
}
```

A completed condition may contain HTTP, timeout, schema, or protocol failures; those are consumed slots. A process/recording failure that leaves a partial condition is different: preserve it, do not resume or rerun it. Diagnose infrastructure and register a new campaign with new directory/snapshot if needed. Between complete conditions you may continue from the next one; do not restart the loop from Liquid. No background scheduler is active. Tool sessions should yield so the human gets useful updates at least once a minute.

After eight complete conditions:

```powershell
python $runner evaluate --campaign-dir $campaign
```

Save command output separately if useful; evaluation.json is write-once. Re-running evaluate may fail because the result already exists. It makes no provider calls. Inspect report files rather than overwriting them.

For a genuinely new campaign after reviewed changes, build current dispatcher once, run appropriate tests/audit, then prepare a NEW directory:

```powershell
dotnet build research/external-cognition/router/FreeDispatch/FreeDispatch.csproj -c Release --no-restore
python $runner prepare --campaign-dir research/external-cognition/router/runs/breadth2 --allowlist-map research/external-cognition/router/allowlist-map.json --preregistration research/external-cognition/router/PROVIDER_PREREGISTRATION.md
```

Do not use this to replace the existing undispatched freeze casually. Frozen source changes are refused by the existing run.

## Compiler, protocol, and evidence invariants

Lab4/protocol.py is a generic structural SQLite kernel: six intents PROPOSE, CHALLENGE, REQUEST_EVIDENCE, REPORT_EVIDENCE, RETRACT, CONCLUDE; exact identities/routes/read refs, claims/provenance/dependencies, claim revision and lifecycle state_revision, directed inboxes, immutable raw submission/event evidence, canonical duplicate-free JSON without floats. It does not solve mathematics or decide correctness. Coherent stale proposals are retained as potential forks, with main state unchanged. Explicit administrative archival requires a workable prevailing-state attestation and still-current accepted outcome evidence. No automatic merge or fork discard.

Full arm asks the model for the entire envelope. Payload arm asks only for coefficients, review assessment/optional corrected coefficients, or final status/x/y. The wrapper supplies known metadata using the exact role-specific context frozen **before** inference. It never refreshes refs after a reply, computes coefficients, selects correct candidates, repairs text, strips code fences, or forwards private reasoning fields. Raw content is retained before strict parsing; compiled envelope is a separate hashed artifact. Invalid payload is retained unchanged and structurally rejected. Missing payload has null validity; invalid returned payload has false validity.

Study HARNESS_REVIEW_NOTES.md before further changes. Prelive defects included header-only timeout, wrong executable ancestor, dropped usage, unhashable assessment, missing failed-payload receipts, unenforced frozen prompt hashes, unchecked completion digests, refreshed stale refs, missing initial compile contexts, and accidental reuse of the last loop's compile context across both futures. These were fixed and tested before the current freeze. Keep meaningful integration tests; callable transport mocks alone missed the launcher defect.

Each condition has isolated pilot stores; requests and later prompts are written before send. Complete HTTP bodies, exact assistant bytes, compiler receipts, compiled envelopes, protocol receipts, per-slot outcomes, safe metadata, nullable usage, model ID and finish reason are separate. Source/input/runtime/initial-prompt identities are checked on campaign load; completion digests bind 12 saved slots. Hashes are integrity evidence, not protection against a malicious coordinator rewriting every artifact consistently. Independent postrun audit must reconstruct public targets, mathematical scores, exact byte/hash relationships, routes, attempt counts, and protocol event replay.

## Reporting and independent postrun audit

Use a fresh independent validator with bounded file pointers and no ability to change implementation. Report per family and representation: scheduled/attempted/completed slots, HTTP and protocol/payload validity, proposal correctness, useful review/candidate quality, shared and raw final correctness, missing usage, tokens and wall time. Include failed slots in declared denominators; label conditional-on-response metrics separately. Preserve every failure; never silently drop a weak model or turn an HTTP failure into evidence of reasoning incapacity.

Two cases per condition are calibration, not broad success-rate or causal estimates. Full facts allow integrators to recompute, so correct shared answers alone do not prove dependence on the shared claims. Extra inference/resources differ from raw control. Concurrent HTTP does not prove simultaneous compute; deterministic envelopes do not make stochastic inference deterministic. Matching/partial useful performance can still support cooperative feasibility. Stronger claims about exceeding internal capacity or harder tasks require separately designed controls.

Write a canonical router/RESULTS.md with independent audit/data and replay/hash/resource evidence. Link it from root CURRENT_WORK/GENERAL_STATE/INDEX/HUMAN_HANDOFF/orchestrator_state. Then broaden tasks rather than treating 96 requests on two problems as large task coverage.

## Finish Lab 5 after the first campaign

Read lab5/DESIGN.md and PREREGISTRATION.md. Fixed six public seeds are 5103,5110,5115,5121,5122,5129; eight variables domain0..3, two four-variable components with binary allowed-pair cycle constraints and two bridges. Public cases have 3–10 local solutions/component and exactly one global solution. Independently enumerate to verify these properties; never expose private/case-key.json to subjects or import generator/oracle into live compilation/submission paths.

Planned schedule is 72 fresh requests: six cases × Liquid/North × six roles. Full public constraints to every role; parallel local enumeration, parallel cross-review, parallel shared/raw integration; family order alternates by case. Same 4096/0.6/180-second settings. Compact tuple-list/assessment/assignment payloads; wrapper inserts only pinned bookkeeping, never computes missing tuples. Current prereg proposes at least4/6 correct finals as descriptive useful performance for each family/condition and separately requires sound+complete accepted component proposals to label a cooperative complete case. This threshold was set before any Lab5 model output.

The generator, public cases and private key were written, and pilot.py is partial. Complete offline_evaluate.py, tests, CLI/runner/documentation and source/runtime freezes. Verify no oracle import/leakage, public uniqueness/local counts, exact strict payloads, per-future pinned refs, no-response receipts, real frozen launcher path, one-call failure handling, 72-outcome gate, hashes and replay. Independently audit before dispatch. Reuse the reviewed FreeDispatch package and Liquid/North allowlists; do not copy the whole affine harness unnecessarily. No Lab5 inference has been sent.

Nominal total primary sends would be96+72 plus setup8 (seven Kilo, one OpenRouter). Shared IP/account free quotas and elapsed window still matter. Record quota failures honestly; do not purchase or use paid fallback. If a later iteration is needed, preserve prior freezes and preregister the next intervention.

## Agent reconstruction and final checkpoint work

Last roles: c4_pilot built the affine provider harness; c3_validator independently audited; c4_engine built dispatcher then began Lab5. All subsequently quota-failed. Rehydrate them with small file-pointer packets after quota reset if useful; don't rely on missing final messages. Native peer communication is authorized. Do not spawn more than the host/user limits or use stronger paid routes merely because quota is exhausted.

At this handoff, local work is committed at c1e9ef1. Router, Lab5, this manual and updated root state may be uncommitted until the final handoff checkpoint. Check git status/log to learn the actual checkpoint. Commit ONLY research after integrity checks; preserve the user's unrelated untracked paths. `git diff --check` may flag whitespace in exact raw outputs: do not edit raw evidence to satisfy style checks; check authored files separately and document the distinction. Never claim experimental results merely because source tests passed.

The next meaningful action is **execute the already frozen, audited breadth1 campaign**, then score/audit it, finish/audit Lab5, and obtain broad completed outcomes. User's current request is the handoff manual; do not resume experimental calls in the remainder of this handoff turn.
