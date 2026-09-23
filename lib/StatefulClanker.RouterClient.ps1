# Thin PowerShell client for the compiled machine-wide router service.
function Get-SCCompiledRouterExecutable {
    if($env:STATEFULCLANKER_ROUTER_EXE -and (Test-Path -LiteralPath $env:STATEFULCLANKER_ROUTER_EXE -PathType Leaf)){return [string]$env:STATEFULCLANKER_ROUTER_EXE}
    if($env:STATEFULCLANKER_DISABLE_COMPILED_ROUTER -match '^(?i:1|true|yes)$'){return $null}
    $installRoot=if($script:StatefulClankerHome){[string]$script:StatefulClankerHome}else{Split-Path -Parent $PSScriptRoot}
    $candidates=@(
        (Join-Path $installRoot 'router\StatefulClanker.Router.exe'),
        (Join-Path $installRoot 'install\router-publish\StatefulClanker.Router.exe'),
        (Join-Path $installRoot 'src\StatefulClanker.Router\bin\Release\net8.0-windows\win-x64\publish\StatefulClanker.Router.exe'),
        (Join-Path $installRoot 'src\StatefulClanker.Router\bin\Debug\net8.0-windows\StatefulClanker.Router.exe')
    )
    foreach($candidate in $candidates){if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}}
    return $null
}

function Test-SCCompiledRouterAvailable {
    return [bool](Get-SCCompiledRouterExecutable)
}

function Invoke-SCCompiledRouterCommand([string[]]$Arguments) {
    $exe=Get-SCCompiledRouterExecutable
    if(-not$exe){throw 'Compiled router is not available.'}
    $raw=& $exe @Arguments 2>&1|Out-String
    $code=$LASTEXITCODE
    $lines=@($raw -split [Environment]::NewLine|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
    if($lines.Count-eq0){throw "Compiled router returned no response (exit $code)."}
    try{$response=$lines[-1]|ConvertFrom-Json -ErrorAction Stop}catch{throw "Compiled router returned malformed JSON (exit $code): $raw"}
    if(-not$response.PSObject.Properties['ok']){throw "Compiled router response is missing ok: $raw"}
    return $response
}

function Get-SCCompiledRouterSnapshot {
    $response=Invoke-SCCompiledRouterCommand @('snapshot')
    if(-not[bool]$response.ok){return $null}
    return $response.data
}
