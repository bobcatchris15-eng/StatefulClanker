# Extend the control-plane instructions without duplicating the full intent/event contract.
$script:SCBaseControlPlaneInstructions = ${function:Get-SCControlPlaneInstructions}
function Get-SCControlPlaneInstructions {
    $base=& $script:SCBaseControlPlaneInstructions
    return $base+@'

WORKER BACKENDS

StatefulClanker may execute a bounded task through either a provider-owned CLI harness or its own minimal direct-inference harness. Treat both as interchangeable execution backends above the same current directives, reconciled Intent, task, freshness, critic, validator, and event machinery.

A CLI backend delegates the inner coding-agent loop to tools such as Codex, Antigravity, Claude, OpenCode, Gemini, or another configured CLI. An API backend points at a machine-local connection profile and uses StatefulClanker's inherent worker loop. That loop always remains bounded by StatefulClanker authority, but its actual tool set is resolved per invocation through worker capability policy: repository operations, read-only human/normalized Intent views, and explicitly authorized external MCP tools may be present. Do not assume a direct worker has a capability merely because another direct worker did.

API connections are intended especially for local OpenAI-compatible endpoints and gateways such as OpenRouter, but the task should not depend on a vendor transport unless the human explicitly requires one.

Do not pin semantic work classes, task sizes, critic, or validator roles to particular models. Normal inference comes from the project target pool and pseudo-round-robins across healthy workhorse routes. A named provider/model override is an operator/debug escape hatch, not planning metadata. API credentials and external-tool secrets are machine/user-local and must never be copied into project state or human-source artifacts.

On the normal Windows path, a resident autofill supervisor owns execution dispatch for the active project. It periodically fills vacant slots from already-ready tasks up to maxConcurrent. The conversational plane should therefore concentrate on directives, Intent, planning, task readiness, and blocking decisions instead of issuing a new run call after every worker completion. Manual run tools may fail closed while autofill is resident to prevent competing worktree/merge schedulers.
'@
}
