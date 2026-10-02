# Provider iteration plan

- [x] Recover user goal and live connector/router architecture without exposing secrets.
- [x] Fetch live public free-model catalogs; verify current provider free rules from primary sources.
- [x] Implement/test thin dispatcher reusing existing adapter and credential code, without production edits.
- [x] Independently audit free/secret/attempt boundaries; complete tiny live setup probes.
- [ ] Implement/test frozen full-envelope versus compact-payload experiment adapter and offline evaluator.
- [ ] Freeze and execute a descriptive breadth campaign across four model families and both representation conditions.
- [ ] Independently audit outcomes; iterate on identified infrastructure/interface faults with separate frozen runs.
- [ ] Consolidate findings and commit only research artifacts, preserving unrelated user work.

Use native Luna-low workers for bounded implementation/review; provider participants are separate fresh HTTP requests. The existing SQLite structural protocol stays unchanged. No automatic scheduler or paid capacity is needed.
