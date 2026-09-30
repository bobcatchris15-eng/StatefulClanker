# Connection health scope repair

Confirmed: 2026-09-30 16:33 OpenRouter inkling:free agentic-harness model403 quarantined entireconnection. Credential budget probes reportavailable; modelaccess andaccountvalidity are distinct. OpenCodeGO subscriptionrequired andMistral APIbudgetexhausted remain legitimate accountblocks.

Implement using TDD in existing router-repair worktree:
1. Permission failures default to endpoint scope. Elevate to connection only with explicit credential/account/subscription-wide evidence; model/harness/region/modelentitlement restrictions remainendpoint, even ifgeneric403. Auth401 and billing402 retain currentaccount handling. Thread contextualscope through gateway/engine/reducer/monitor so their diagnoses and healthkeys agree.
2. Endpointpermission restrictions receive bounded retry/cooldown (not permanent quarantine ignored by monitor). Connectionauth/account restrictions remain quarantine until matching config change or authoritative credential recovery. Metadataavailability/quota alone must not unblock billing or model access, and unrelated metadataerrors must not block inference connection.
3. Recover existing false connectionpermission quarantine using stored message evidence and new policy, preserving auth/billing/explicitaccountblocks. Prefer automatic policy migration by reducer/engine at startup/tick, emit auditable healthrecovery withscope-correctionreason. Do not blindly reset live health JSON. If original offending endpoint cannotbe identified, allownextrealrequestto establishendpoint restriction ratherthan guess.
4. Tests must replay realmodel403 withsameconnection siblingmodel stillusable; explicitsubscriptionaccountblocked; generic403boundedendpoint; strictpin respected; credential401unchanged; oldmodelquarantine heals whiletrueaccountquarantine stays; quotasuccessdoesnotclearaccountblock; metadata403/404/429/500donotpoisonwholeconnection. Run relevant existing router/quota/probe suites and independentreview.
5. Publishrouteronly, preservebackup, installafteridleworkers/supervisor/leases withrepeatedguards. KeepdashboardPi running. VerifyliveOpenRouterconnectionfalseblockclearedandlegitimateblocksretained; no paidprobes necessary.

Review decisions:
- Generic legacy permission blocks without account evidence are returned to eligibility; the original endpoint cannot be inferred safely, so the next real request establishes its restriction.
- Account permission evidence is stored before message truncation. Explicit account-wide predicates are required; account/model proximity alone does not prove account failure.
- Hard auth/account permission restrictions retain quarantine even with Retry-After. Quota metadata remains telemetry, not proof of restored model access.
- Policy corrections and cooldown expiry do not fabricate lastSuccess observations. Both migration and expiry recheck authoritative current state under the store lock, so stale snapshots cannot erase newer hard blocks.
- Metadata HTTP regressions require observed server readiness and a response-sent marker.
