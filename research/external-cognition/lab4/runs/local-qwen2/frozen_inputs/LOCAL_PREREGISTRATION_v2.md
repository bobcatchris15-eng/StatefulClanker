# Local Qwen replication 2: bounded output after endpoint diagnostics

Date: 2026-10-01. The first local run was interrupted on the user's direction to test the endpoint and adjust Lemonade settings as needed. Its six attempted requests and remaining six unattempted slots remain preserved separately. No score is assigned to its incomplete schedule. Two proposer requests timed out, two review responses arrived (one structurally accepted, one invalid JSON), and two integrator requests were interrupted before collection.

Direct endpoint diagnostics returned READY, valid {"ok":true}, and ALPHA/BETA in a concurrent pair. Short requests completed in about 2–5 seconds, while returned usage reported about eight decoding tokens per second for the longer review responses. Pair timings are consistent with backend serialization, not proof of physical parallel model execution. No Lemonade setting was changed by the coordinator. The loaded context remains 70728.

## Fixed intervention and question

Use the same two cases, complete problem facts, structured claim/review protocol and twelve fresh-role schedule as before. Change the requested per-call output allowance from 4096 to 512 tokens, retaining temperature 0, stream false, and timeout 300 seconds. This is a new exploratory feasibility run after transport calibration, not a retry/replacement of the previous frozen run and not a confirmatory accuracy comparison. Selection of these settings is informed by observed transport speed. The expected shorter upper bound is approximate: the server may count tokens differently or exceed wall-clock expectations.

Run the exact already-loaded local qwen3.5-9b-FLM (checkpoint qwen3.5:9b, FLM NPU backend). Verify current context/model/server metadata before dispatch, and freeze the new runner source, this preregistration, runtime discovery, schedule and initial inputs. Do not alter server settings mid-run. Each request has one user message and no previous chat history. Dispatch pairs concurrently; permit backend serialization and record timing honestly. The first run's messages, reasoning and results are not passed to these participants.

## Evidence and acceptance

Save exact request bodies and full HTTP responses before content extraction; permit only the frozen registry ID or checkpoint alias as the returned model. Preserve final content exactly, without markdown stripping, brace completion, repairs, retries, alternative samples, reasoning substitution or evaluator feedback. Missing, malformed, truncated and transport-failed outputs consume their scheduled slots. Save available usage, finish reasons, wall time, returned model name and structural receipts. No hidden domain correctness is checked online.

Only after all twelve slots have outcomes, evaluate and independently audit from public observations and retained bytes. Report both cases individually, original relation accuracy, review disposition/candidates, final raw-answer accuracy and protocol-valid correctness, resource usage and schema/transport attrition. Primary goal is useful cooperative local performance; superiority over raw controls is unnecessary. Two cases do not establish a general 50% success rate, harder-task scaling, universal reasoning representation or native capacity extension. No stale-fork trial is included; existing mechanical tests cover fork retention and archival.

If the user redirects work again, preserve an interruption receipt and do not score unattempted slots as model errors. Settings and source revisions after freeze require a distinct run, not repair of this one.
