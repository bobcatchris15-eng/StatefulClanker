# Lab 3 preregistration

## Question and scope

Can a native reasoning call write a compact external state that a fresh reasoning call can use to recover a hidden answer, and how does that answer behave under removal, corruption, raw evidence, and revision? The unit is one generated affine world. This is a three-case mechanism demonstration; it is not an estimate of population performance, a model comparison, or evidence that native capacity has been extended.

## Frozen design

Before any live calls, freeze the generator, evaluator, prompt templates, and protocol. Use prime modulus 11 and fixed seeds 3101, 3102, and 3103. Each world has an invertible two-coordinate affine map. The producer receives three noncollinear observations and the declared affine family, but not the target. It emits the inferred relation as versioned external state. A fresh downstream call receives the target and one of four conditions: intact state, state with the relation omitted, state with the u intercept altered by +1 mod 11, or the original raw observations. Each call starts with a fresh context; downstream calls receive no producer transcript. The store checks only schema, version, and references; it does not judge mathematical correctness. Save exact prompts and raw responses before any offline scoring.

Per world, schedule one producer, four downstream arms, one revision producer, and one revision consumer: 7 calls per world, 21 planned calls total. Shuffle arm order deterministically from the seed and record the realized order. The initial producer is target-free. Revision producer receives authoritative replacement u observations, prior state, and the intact consumer's raw response (including a wrong response, if any); it receives neither the target nor evaluator feedback. It must supersede old u evidence, preserve v, and mark the cached answer invalid. The revision consumer receives the original target and revised state in a fresh context. The +2 mod 11 u-intercept revision is designed to change the target solution. Explicit invalidation is part of the prompt, so success does not demonstrate autonomous dependency discovery. Use the same neutral response status choices in every consumer arm.

## Outcomes and scoring

Score offline with an independent evaluator after every raw response is saved. It checks producer coefficients against the generated relation and enumerates coordinate candidates implied by each consumer's supplied relation. Primary outcome per case is exact recovery of the target coordinates in the intact-state arm, conditional on structural acceptance of the producer patch. Structural acceptance is not a semantic gate: a shape-valid but wrong producer relation still receives all downstream and revision calls. Report the raw-evidence arm separately as a baseline for whether the observations support fresh inference.

For the altered arm, report both exact agreement with the true world and exact agreement with the answer implied by the altered relation. For the omitted arm, classify an explicit statement that the answer is not determined from supplied information as “undetermined”; do not score it as a wrong coordinate answer. Any concrete coordinate answer is scored against the true world and reported separately. For revision, score exact agreement with the revised relation's target solution and verify that the revised relation preserves v while replacing u. Record whether the producer invalidated the cached answer; interpret this only as compliance with an explicit instruction.

Report case-level outcomes and simple counts across the three fixed cases. Do not use significance tests, population estimates, or a pooled percentage as a general capability claim. Record input/output size or token counts when available, but do not claim resource equality: the raw-evidence arm necessarily carries a different representation and call/compute budgets are not matched.

## Attrition and leakage

Do not repair, replace, or retry a malformed producer response. Preserve the rejection and omit all downstream arms and revision calls for that case. A shape-valid but semantically wrong producer state still receives every planned downstream and revision call. If a revision response is malformed, omit its revision consumer. Preserve malformed consumer responses as attrition. Report planned and completed calls and the reason for every omission. No evaluator result, correctness label, or semantic hint may reach a live call. Structural validation errors may be returned only as the store's ordinary schema-level rejection; they must not reveal mathematical correctness. Do not add calls after observing outcomes.

## Interpretation boundary

Intact success with a correct producer state shows that the external relation was sufficient for this fresh call on this case. The raw arm checks whether the original evidence also supports the inference. Differences between these arms do not establish efficiency or superiority because their representation and resource budgets differ. Omission and alteration are diagnostic controls; revision tests a prompted update path. Three worlds, one model/configuration, and explicit prompts leave broad generalization and autonomous state maintenance untested.
