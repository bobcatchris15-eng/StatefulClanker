# Research Branch: Intent, Goals, and Planning Control Plane

> **Status:** Research only. Do not merge into `main` as implementation work without an explicit design decision.
>
> **Branch:** `research/intent-planning-control-plane`
>
> **Fork point:** `main` at `936d4fdaa5a0483122959244995dede5c59f6d03`

## Purpose

Explore a more rigorous planning/decomposition architecture for StatefulClanker while the implementation-worker suite continues to stabilize independently on `main`.

The research target is a bidirectional planning control plane in which the user-facing Clanker captures and refines user intent, planning agents expose uncertainty and implications, the control plane resolves what it can automatically, and only genuinely human-owned decisions are escalated back to the user.

This branch is deliberately isolated so experimental planning models, schemas, prompts, and prototypes do not become accidental dependencies of the production worker path.

## Working model

Candidate planning pipeline:

```text
conversation
  -> intent elicitation
  -> normalized intent contract
  -> ambiguity / implication probing
  -> clarification broker
  -> architecture / obligation graph
  -> decomposition
  -> task adversaries
  -> graph reconciliation
  -> compression / atomization
  -> executable task packets
  -> execution evidence
  -> intent compliance / replanning
```

The loop is bidirectional:

```text
User <-> User-facing Clanker <-> Clarification / Decision Broker
     <-> Planning Agents <-> Task / Obligation Graph <-> Execution
```

## Research questions

1. What is the minimum useful machine-readable representation of user intent?
2. Which fields must preserve provenance, authority, confidence, and mutability?
3. How should goals, requirements, constraints, assumptions, preferences, non-goals, obstacles, and decisions differ structurally?
4. What kinds of uncertainty can Clanker resolve autonomously from project state, code, prior decisions, and other agents?
5. What kinds of decisions must be escalated to the human?
6. How should multiple heterogeneous models contribute without merely duplicating each other's work?
7. How should disagreement between agents become structured information rather than majority voting?
8. How do task nodes trace upward to intent and downward to completion evidence?
9. How does the system distinguish verification of implementation from validation of user intent?
10. How should accepted execution results update the planning model so the task graph reflects current reality instead of the original plan?

## Candidate intent object

A likely internal object is an **Intent Contract** containing some subset of:

- purpose / rationale
- desired end state
- goals
- invariants
- constraints
- non-goals
- preferences
- beliefs about current project state
- assumptions
- unresolved decisions
- obstacles / failure conditions
- success criteria / fit criteria
- responsibility / ownership
- provenance
- authority
- confidence
- mutability
- traceability links

The intent model should distinguish authoritative user statements from inferred planner assumptions. No inferred preference should silently become equivalent to a user requirement.

## Candidate goal semantics

KAOS-style goal classes appear especially useful:

- **ACHIEVE** — make a condition true.
- **MAINTAIN** — keep a condition true.
- **AVOID** — prevent a condition from becoming true.
- **CEASE** — make a currently true condition stop being true.

Goals should primarily describe states. Operational tasks should be derived later.

## Clarification / decision channel

Planning agents should be able to emit structured clarification requests rather than failing or directly questioning the human.

Candidate fields:

- question
- why_it_matters
- affected_goals
- affected_tasks
- blocking_level
- reversibility
- candidate_answers
- evidence_already_available
- can_infer
- recommended_default
- decision_owner
- provenance

Resolution order should favor autonomous resolution before human interruption:

```text
project state
-> code / repository
-> reflexive project knowledge
-> prior user decisions
-> peer planning agents
-> user-facing Clanker synthesis
-> human escalation
```

A useful escalation heuristic is approximately:

```text
uncertainty x impact x irreversibility
```

Only sufficiently consequential unresolved questions should interrupt the human.

## Multi-agent planning roles under investigation

Rather than several agents producing competing full plans, use heterogeneous agents with deliberately different epistemic jobs:

- intent interrogator / requirements expander
- architecture reasoner
- code implications agent
- state / data implications agent
- UX / runtime implications agent
- failure-mode / obstacle agent
- domain specialist
- decomposer
- task adversary
- graph reconciler
- contrarian planner
- compression agent
- task shrinker / cold-worker readiness checker

Candidate pattern:

```text
expand -> challenge -> reconcile -> compress -> atomize
```

## Execution intent

Each worker should receive a small local intent packet rather than the entire planning corpus:

- purpose
- local desired end state
- key invariants
- local task
- relevant context
- permitted freedom
- required evidence
- escalation boundaries

This resembles the useful parts of commander's intent: subordinates can adapt locally without losing the purpose of the work.

## Traceability rule

Working design rule:

> **No task without a reason. No goal without evidence.**

Every executable task should trace upward to a requirement, goal, constraint, obstacle mitigation, or decision.

Every completed leaf goal should trace downward to observable evidence showing that its fit criteria were met.

## Prior art to study

### Intent-Based Systems / IRTF

RFC 9315, *Intent-Based Networking - Concepts and Definitions*.

Useful concepts:
- declarative intent
- refinement and translation
- orchestration
- assurance
- intent validation
- conflicts
- iterative user refinement
- inner autonomous loop / outer human loop
- validated intent as a source of truth

https://datatracker.ietf.org/doc/html/rfc9315

### KAOS goal-oriented requirements engineering

Useful concepts:
- WHY upward / HOW downward goal refinement
- AND/OR goal decomposition
- obstacles
- responsibility assignment
- operationalization
- Achieve / Maintain / Avoid / Cease goal forms

### Volere requirements specification

Useful concepts:
- rationale
- source / originator
- fit criterion
- priority
- dependencies
- supporting material
- explicit requirement metadata

### NASA systems engineering / requirements flowdown

Useful concepts:
- stakeholder expectations vs technical requirements
- requirements derivation
- bidirectional traceability
- verification vs validation

### i* / Tropos

Useful concepts:
- actors
- goals
- soft goals
- tasks
- resources
- intentional dependencies among actors / agents

### Commander's Intent / Mission Command

Useful concepts:
- purpose
- key tasks
- desired end state
- delegated adaptation under changing conditions

### BDI agent models

Useful concepts:
- beliefs
- desires / goals
- committed intentions

Potentially useful as agent runtime-state semantics, but probably not as the top-level user intent format.

### PDDL / HTN planning

Useful concepts:
- explicit state
- preconditions / effects
- hierarchical action decomposition

Likely most useful after semantic ambiguity has been resolved.

## Boundary with main

For now:

- **main** continues refining implementation workers, routing, validation, restart behavior, telemetry, and the current control plane.
- **this branch** is for research, schemas, experiments, planning-agent prompts, and disposable prototypes related to intent capture and planning/decomposition.
- No dependency from `main` to this branch should be introduced during research.
- Any eventual integration should be deliberate and sliced into independently reviewable changes after the worker suite is considered stable enough.
