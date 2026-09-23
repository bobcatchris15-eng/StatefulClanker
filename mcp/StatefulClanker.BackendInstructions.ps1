# Extend the control-plane instructions without duplicating the full intent/event contract.
$script:SCBaseControlPlaneInstructions = ${function:Get-SCControlPlaneInstructions}
function Get-SCControlPlaneInstructions {
    $base=& $script:SCBaseControlPlaneInstructions
    return $base+@'

WORKER BACKENDS

StatefulClanker may execute a bounded task through either an explicitly selected provider-owned CLI harness or its own direct-inference worker. They share the same authority/task/evidence contract, but they are not assumed to have identical runtime capabilities: direct workers own resumable transcripts and controlled tools; CLI harnesses own their inner session/tool behavior. Whole-project review is separate from the per-task worker/validator cycle.

A CLI backend delegates the inner coding-agent loop to tools such as Codex, Antigravity, Claude, OpenCode, Gemini, or another configured CLI. An API backend points at a machine-local connection profile and uses StatefulClanker's inherent worker loop. That loop always remains bounded by StatefulClanker authority, but its actual tool set is resolved per invocation through worker capability policy: repository operations, read-only human/normalized Intent views, and explicitly authorized external MCP tools may be present. Do not assume a direct worker has a capability merely because another direct worker did.

API connections are intended especially for local OpenAI-compatible endpoints and gateways such as OpenRouter, but the task should not depend on a vendor transport unless the human explicitly requires one.

Do not pin semantic work classes, task sizes, critic, or validator roles to particular models. Normal inference comes from the machine endpoint pool and pseudo-round-robins across healthy enabled routes. Operator routing hints have three explicit levels: no hint uses the full pool; connection selects one provider/account while retaining failover among its enabled endpoints; endpoint strictly pins one exact connection/model entry. Provider selects an explicit compatibility CLI backend only. Provider-native routers such as OpenRouter/Kilo free-router models are ordinary exact endpoints and are often preferable to hard-coding one underlying free model. API credentials and external-tool secrets are machine/user-local and must never be copied into project state or human-source artifacts.

On the normal Windows path, a resident autofill supervisor owns execution dispatch for the active project. It periodically fills vacant slots from already-ready tasks up to maxConcurrent. The conversational plane should therefore concentrate on directives, Intent, planning, task readiness, and blocking decisions instead of issuing a new run call after every worker completion. Manual run tools may fail closed while autofill is resident to prevent competing worktree/merge schedulers.
'@
}
