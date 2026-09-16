# Extend the control-plane instructions without duplicating the full intent/event contract.
$script:SCBaseControlPlaneInstructions = ${function:Get-SCControlPlaneInstructions}
function Get-SCControlPlaneInstructions {
    $base=& $script:SCBaseControlPlaneInstructions
    return $base+@'

WORKER BACKENDS

StatefulClanker may execute a bounded task through either a provider-owned CLI harness or its own minimal direct-inference harness. Treat both as interchangeable execution backends above the same current directives, reconciled Intent, task, freshness, critic, validator, and event machinery.

A CLI backend delegates the inner coding-agent loop to tools such as Codex, Antigravity, Claude, OpenCode, Gemini, or another configured CLI. An API backend points at a machine-local connection profile and uses StatefulClanker's minimal read/search/edit/command/git-diff tool loop. API connections are intended especially for local OpenAI-compatible endpoints and gateways such as OpenRouter, but the task should not depend on a vendor transport unless the human explicitly requires one.

Route by semantic work class/capability and project backend name. Do not rewrite task semantics merely because one machine routes `small` work to a local API model and another routes it to a CLI harness. API credentials are machine/user-local and must never be copied into project state or human-source artifacts.
'@
}
