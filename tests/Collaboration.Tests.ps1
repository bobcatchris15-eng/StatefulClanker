$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'lib\StatefulClanker.Collaboration.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "COLLABORATION TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-collab-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try {
    $team=Set-SCCollaborationTeam $temp 'feature-alpha' @('task-a','task-b','task-c') 'negotiate shared touchpoints'
    Assert-True (@($team.taskIds).Count-eq3) 'team roster was not persisted'

    $p=Send-SCCollaborationPacket $temp 'task-a' 'proposal' 'RunId contract' 'RunId is immutable and available before launch.' @() 'feature-alpha' @('ExperimentRunFactory.Create') $null $true
    Assert-True ([bool]$p.id) 'packet id missing'
    Assert-True (@($p.toTaskIds).Count-eq2) 'team broadcast did not exclude sender/include peers'

    $b=@(Get-SCCollaborationInbox $temp 'task-b')
    Assert-True ($b.Count-eq1) 'target inbox did not receive packet'
    Assert-True ([string]$b[0].type-eq'proposal') 'packet type changed'
    Assert-True ([bool]$b[0].requiresAck) 'ack requirement changed'

    $none=@(Get-SCCollaborationInbox $temp 'task-b' @([string]$p.id))
    Assert-True ($none.Count-eq0) 'exclude/consumed packet filter failed'

    $reply=Send-SCCollaborationPacket $temp 'task-b' 'objection' 'Restart semantics' 'Persisted RunId must survive reconstruction.' @('task-a') $null @('ExperimentStore') ([string]$p.id) $false
    $a=@(Get-SCCollaborationInbox $temp 'task-a')
    Assert-True ($a.Count-eq1-and[string]$a[0].replyTo-eq[string]$p.id) 'direct reply packet failed'

    $bundle=Format-SCCollaborationPacketBundle $b
    Assert-True ($bundle -match 'TEAM UPDATE' -and $bundle -match 'ACK REQUESTED') 'model injection bundle omitted cooperation framing'

    $ta=[pscustomobject]@{id='impl-a';createdAt='2026-01-01T00:00:00Z';dependsOn=@();retrieval=@('src/shared.ps1');evidence=@();intentRefs=@();relations=@()}
    $tb=[pscustomobject]@{id='impl-b';createdAt='2026-01-01T00:00:01Z';dependsOn=@();retrieval=@('src/shared.ps1');evidence=@();intentRefs=@();relations=@()}
    $tc=[pscustomobject]@{id='solo-c';createdAt='2026-01-01T00:00:02Z';dependsOn=@();retrieval=@('src/elsewhere.ps1');evidence=@();intentRefs=@();relations=@()}
    $one=Select-SCImplementationDispatchPlan @($ta,$tb,$tc) 1 @()
    Assert-True (@($one.tasks).Count-eq1-and[string]$one.tasks[0].id-eq'solo-c') 'co-op member consumed a lone slot'
    $two=Select-SCImplementationDispatchPlan @($ta,$tb,$tc) 2 @()
    Assert-True (@($two.tasks).Count-eq2-and(@($two.tasks|ForEach-Object{$_.id})-contains'impl-a')-and(@($two.tasks|ForEach-Object{$_.id})-contains'impl-b')) 'viable co-op was not preferred as a formation'
    $join=Select-SCImplementationDispatchPlan @($tb,$tc) 1 @('impl-a')
    Assert-True (@($join.tasks).Count-eq1-and[string]$join.tasks[0].id-eq'impl-b') 'active co-op did not receive first available capacity'

    Write-Host 'PASS: durable collaboration teams, targeted/team packets, evidence, replies, consumption filtering, and compact injection formatting, and formation-first implementation dispatch.'
}
finally {Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
