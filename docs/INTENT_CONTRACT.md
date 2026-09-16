# Current Human Directives and the Intent Contract

StatefulClanker separates **what the human most recently said about a decision** from the control plane's **normalized interpretation of the project**.

That separation exists to prevent two opposite failure modes:

- losing the human's direct wording through repeated model paraphrase
- continually showing workers old instructions that the human later replaced

The working authority chain is:

```text
human conversation
    -> current human directives
    -> reconciled Intent Contract
    -> plan
    -> task
    -> compiled worker truth packet
```

## Current human directives

Current directives live under:

```text
.statefulclanker/directives/current/<directive-id>.json
```

A directive is one named human decision/scope, for example:

```text
ui-project-selection
provider-routing
launcher-types
windows-install-boundary
```

The important rule is:

> Within one directive scope, the latest direct human word is authoritative.

When the human changes a decision, the conversational control plane updates the **same directive id**. The prior revision is removed from current authority and archived under:

```text
.statefulclanker/directives/history/<directive-id>/
```

History is audit/debugging evidence only. It is not normal worker specification.

Each current directive stores:

- stable directive id
- optional semantic scope
- revision
- current direct human wording
- durable `human:<id>` source reference
- governing Intent ids where known
- timestamp/reason metadata

The referenced verbatim human source remains under:

```text
.statefulclanker/input/<source-id>.txt
```

Workers receive the current directive snapshot directly and can inspect the referenced source artifact when they need to verify wording or surrounding source context.

### Superseded source protection

A task created under an older directive may still contain that revision's `human:<id>` reference. StatefulClanker detects directive-origin source artifacts and excludes superseded/retired directive sources from ordinary worker retrieval.

Generic provenance sources are unaffected.

If a directive identifies governing Intent ids, tasks carrying those ids are marked stale when the directive changes. In-flight work is not trusted to commit: directive revision/hash freshness checks reject a result compiled against older authority.

## Directive reconciliation gate

Changing or retiring a current directive does **not** immediately rewrite normalized Intent automatically. Semantic reconciliation belongs to the human-facing reasoning plane.

A directive mutation therefore sets:

```text
directiveReconciliationRequired = true
```

and records the pending directive ids.

New worker compilation fails closed until the conversational control plane:

1. compares the changed directive with all other current directives
2. checks the normalized Intent Contract for contradictions or stale implications
3. asks the human when replacement/narrowing/exception/precedence is unclear
4. commits a complete contradiction-free Intent Contract with `intent_apply` / `intent replace`

The committed Intent revision records the exact current:

- `directiveRevision`
- `directiveHash`

and clears the reconciliation gate.

This makes it mechanically impossible to silently accept new human direction while continuing to compile workers against an older normalized interpretation.

## Intent Contract

The current normalized contract lives at:

```text
.statefulclanker/intent/contract.json
```

Revision history lives at:

```text
.statefulclanker/intent/history/revision-NNNN.json
```

The contract contains:

- `objective`
- `requirements`
- `constraints`
- `invariants`
- `nonGoals`
- `decisions`
- `preferences`
- `openQuestions`
- `successDefinition`
- `directiveRevision`
- `directiveHash`

Intent is orchestrator-owned and worker-read-only. Implementation difficulty is not authority to change it.

## Human-facing orchestrator behavior

The conversational control plane's primary responsibility is **intent fidelity**, not rapid implementation.

It should aggressively identify ambiguity capable of producing materially different implementations. When the host offers a structured question/questionnaire/quiz tool, prefer it.

Useful behavior includes:

- ask contrastive questions when two interpretations are plausible
- do not optimize for fewer human turns
- do not silently choose conventional/easy interpretations just to keep execution moving
- reuse a stable directive id when the human changes an existing decision
- ask whether a newer statement is a replacement, narrowing, exception, or new rule when scope is unclear
- treat `INTENT_QUESTION` / `INTENT_CONFLICT` from workers as successful detection of uncertainty

The control plane should preserve traceability:

```text
current directive / human source -> Intent clause -> plan -> task
```

## Worker truth packet

Every new worker compilation contains directly:

- project goal
- project/state revisions
- **all current human directives** with directive revision/hash
- normalized Intent Contract with revision/hash
- current task and acceptance boundary
- relevant task source/Intent references
- dependency/retrieval evidence

Superseded directive history is not included.

The packet also exposes the canonical `stateRoot`, so a worker can resolve a current directive source reference:

```text
human:h-... -> <stateRoot>\.statefulclanker\input\h-....txt
```

If current direct wording and normalized Intent appear inconsistent, the worker must emit:

```text
INTENT_CONFLICT: <specific conflict>
```

If a material choice remains ambiguous after inspecting the current directive/source:

```text
INTENT_QUESTION: <specific question>
```

The worker does not decide which human intent should win.

## CLI

Current directives:

```powershell
.\StatefulClanker.ps1 directive list
.\StatefulClanker.ps1 directive show -DirectiveId ui-project-selection
```

Set/replace current direct human wording:

```powershell
.\StatefulClanker.ps1 directive set `
  -DirectiveId ui-project-selection `
  -Message "Restore the exact last active project; never silently substitute another." `
  -Scope desktop.project-selection `
  -IntentRef REQ-PROJECT-RESTORE
```

Audit superseded revisions:

```powershell
.\StatefulClanker.ps1 directive history -DirectiveId ui-project-selection
```

Retire a human rule:

```powershell
.\StatefulClanker.ps1 directive retire `
  -DirectiveId ui-project-selection `
  -Reason "Human removed this behavior"
```

Normalized Intent:

```powershell
.\StatefulClanker.ps1 intent show
.\StatefulClanker.ps1 intent history
.\StatefulClanker.ps1 intent escalations
.\StatefulClanker.ps1 intent replace -Path .\intent.next.json -Reason "Reconciled current directives"
```

## Events are not specification memory

The event stream records that directives and Intent changed, but the event stream itself is not current specification.

Current specification comes from:

```text
current human directives + their reconciled Intent Contract
```

That distinction lets StatefulClanker retain a complete audit trail without forcing every future worker to reason through obsolete decisions.
