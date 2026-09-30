# Router inference repair — September 30, 2026

Scope: repair current inference errors only. Harness redesign and candidate/worktree changes deferred.

1. Reproduce HTTP 200 embedded provider errors (502 and 400) through real local HTTP gateway tests. Extend adapter parse result with optional typed provider error status and failure classification. Keep actual HTTP status evidence. Apply the existing provider health and failover policy for embedded errors; unknown response shapes remain request-scoped adapter failures.
2. Reproduce HTTP 400/422 context rejection. Context errors must remain request-scoped, not adapter-suspect, allow another permitted endpoint, and respect strict pins. Add explicit context capacity reason code. Recognize recorded input length / prompt maximum forms.
3. Reproduce empty or malformed tool-call responses with finish_reason length. Do not expose reasoning as answer. Reject non-object/non-JSON function arguments before transcript admission. Diagnose output budget exhaustion explicitly; perform at most two same-endpoint retries with doubled output budget capped at 16384, held lease and one overall timeout, no caller transcript mutation. Diagnostics do not inflate their budgets. Respect known context minus reported prompt usage; preserve all reported usage and HTTP attempt evidence. Do not replay valid content/tool output merely because finish reason is length.
4. Run existing router/adapters/failover/worker bridge suites, independent review, build self-contained router release and install only after verifying no live inference leases/workers. Preserve rollback copy. Do not restart dashboard or kill workers/Pi.

Validation: fail each new regression on baseline before fix, green after. Real local HTTP server assertions on route selected, wire output budget, health state, unchanged transcript, retry count, actual HTTP evidence, malformed tool rejection, total reported usage, strict pins, generic malformed responses. No paid live probes needed.

Review refinement: adapt the existing PowerShell router-result accounting to consume per-HTTP attempt usage on both success and failure; this is compatibility work for the router response, not a worker harness redesign. Independent review found statusless error envelope and early error usage loss; covered with regressions.
