# Prelive review record

Root and independent validator reviewed the campaign harness before experimental dispatch. Setup probes are separately retained and excluded from accuracy.

Material issues found and routed to the implementation worker:

- Dispatcher timeout originally bounded headers but not body; fixed with a linked deadline through body acquisition/read, with retained incomplete evidence.
- Unsafe/nonempty output rejection could write failure receipts; fixed to return without writing there.
- Default launcher originally derived its package path from the wrong ancestor; fixed to use the frozen allowlist's input directory. Fake callable transports alone did not cover this boundary.
- Usage metadata expected nested usage while actual dispatcher exposes top-level fields; corrected to retain nullable reported usage.
- Unhashable reviewer assessment could escape schema rejection and leave no compile receipt; explicit string guard and regression required.
- Payload transport failures lacked compile receipts needed by evaluation; distinguish absent payload (`null` validity) from invalid returned payload (`false`).
- Completion markers were not bound to saved slot records; verify status/count/canonical digest.
- Payload compiler could refresh references after inference; freeze the presented compile context before dispatch.
- Prepared proposer prompts need their initial compile contexts frozen as well as dynamic later contexts.
- Compile context was captured in the preparation loop but not bound per future; each response must carry its own role's context.
- Initial condition/prompt freeze hashes were recorded but not enforced against coordinated prompt/hash-file edits; validate immutable initial hashes while permitting later additions.

Clearance belongs to the independent HARNESS_PRELIVE_AUDIT.md, not this coordination note. New findings and final verification should be reflected there. No correctness feedback or coordinator-authored solution is permitted during execution.
