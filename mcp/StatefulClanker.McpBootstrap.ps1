# Shared MCP dispatch composition for both transports. Order matters: each layer
# wraps the Invoke-McpRpc function supplied by the layer before it.
. (Join-Path $PSScriptRoot 'StatefulClanker.McpCore.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.McpExtensions.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.BackendInstructions.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.McpWorkerPolicy.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.McpProtocol.ps1')
. (Join-Path $PSScriptRoot 'StatefulClanker.SubscriptionPump.ps1')
