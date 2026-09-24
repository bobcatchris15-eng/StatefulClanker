<#
RPK lesson surface tests: MCP tool arg mapping, worker record_lesson path
confinement/cap/rate-limit, policy deny honoured, and event emission.
Stubs the RPK wrappers so no native host is required.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "RPK LESSONS TEST FAILED: $Message"}}

# --- Worker-side (record_lesson) -------------------------------------------------
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-rpk-lessons-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $temp|Out-Null
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $temp 'local';New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA|Out-Null
try {
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1');Set-SCRoots $temp $temp
    New-Item -ItemType Directory -Force -Path (Join-Path $temp '.statefulclanker') | Out-Null
    $script:events=@()
    function Add-SCEvent([string]$Type,$Message,$Data) { $script:events += ,[pscustomobject]@{type=$Type;message=$Message;data=$Data} }
    function Resolve-SCSourceReference { param([string]$SourceRef); return $null }
    function Get-SCIntentContract { return [pscustomobject]@{} }
    function Get-SCIntentHash { param($Contract); return 'h' }
    function Get-SCCurrentDirectiveSnapshot { return [ordered]@{} }
    $script:addLessonCalls=@()
    function Add-SCRpkLesson([string]$Title,[string]$Body,[string[]]$Tags=@(),[string[]]$Paths=@(),[string]$Source='worker',[double]$Confidence=.75) {
        $script:addLessonCalls += ,[pscustomobject]@{title=$Title;body=$Body;tags=$Tags;paths=$Paths;source=$Source;confidence=$Confidence}
        return [pscustomobject]@{id='lesson-1';title=$Title}
    }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1');function Invoke-SCProvider { throw 'CLI provider path not expected.' };. (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')

    $task=[pscustomobject]@{id='task-1';role='worker'}
    'nested' | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $temp 'sub') | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $temp 'sub\f.txt') -Encoding UTF8

    $registry=@(Get-SCWorkerToolRecords $task 'worker')
    $recordLesson=$registry|Where-Object{$_.wireName-eq'record_lesson'}
    Assert-True ($null-ne$recordLesson) 'record_lesson tool was not advertised by default.'

    $args1=[pscustomobject]@{title='Trap: X';body=('y'*2000);paths=@('sub\f.txt');tags=@('gotcha')}
    $r1=Invoke-SCWorkerTool 'record_lesson' $args1 $task 'worker' $registry
    Assert-True ($script:addLessonCalls.Count-eq1) 'Add-SCRpkLesson was not invoked.'
    Assert-True ($script:addLessonCalls[0].body.Length-eq1500) "Body was not capped to ~1500 chars, got $($script:addLessonCalls[0].body.Length)."
    Assert-True ($script:addLessonCalls[0].source-eq'worker:task-1') "Source was not worker:<taskId>, got '$($script:addLessonCalls[0].source)'."
    Assert-True ($script:addLessonCalls[0].confidence-eq.6) 'Default confidence for worker lessons should be 0.6.'
    Assert-True (@($script:events|Where-Object{$_.type-eq'rpk.lesson_recorded'}).Count-eq1) 'rpk.lesson_recorded event was not emitted.'

    $escapeArgs=[pscustomobject]@{title='t';body='b';paths=@('..\outside.txt')}
    $escaped=$false
    try{[void](Invoke-SCWorkerTool 'record_lesson' $escapeArgs $task 'worker' $registry)}catch{$escaped=$true}
    Assert-True $escaped 'A path escaping the worker root must be rejected.'

    for($i=0;$i-lt4;$i++){[void](Invoke-SCWorkerTool 'record_lesson' ([pscustomobject]@{title="t$i";body='b'}) $task 'worker' $registry)}
    $rateLimited=$false
    try{[void](Invoke-SCWorkerTool 'record_lesson' ([pscustomobject]@{title='over';body='b'}) $task 'worker' $registry)}catch{$rateLimited=$true}
    Assert-True $rateLimited 'record_lesson must be rate-limited to ~5 calls per session.'

    # Workers cannot confirm/reject: no such wire tools exist in the worker registry.
    Assert-True ((@($registry|Where-Object{$_.wireName-in@('rpk_lesson_confirm','rpk_lesson_reject','confirm_lesson','reject_lesson')}).Count)-eq0) 'Workers must not be able to confirm/reject lessons.'

    # Policy deny honoured: project policy denies rpk.* -> tool must disappear.
    $policy=[ordered]@{schemaVersion=1;allow=$null;deny=@('rpk.*');roles=[ordered]@{};stages=[ordered]@{}}
    $policy|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Get-SCWorkerPolicyProjectPath) -Encoding UTF8
    $registryDenied=@(Get-SCWorkerToolRecords $task 'worker')
    Assert-True ((@($registryDenied|Where-Object{$_.wireName-eq'record_lesson'}).Count)-eq0) 'Policy deny for rpk.* did not remove record_lesson.'

    Write-Host 'PASS: worker record_lesson tool (cap, path confinement, rate limit, policy deny, event).'
} finally {
    $env:LOCALAPPDATA=$oldLocal;Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Control-plane side (MCP tools arg mapping) ----------------------------------
$temp2=Join-Path ([IO.Path]::GetTempPath()) ('sc-rpk-mcp-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $temp2|Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $temp2 '.statefulclanker') | Out-Null
'{}' | Set-Content -LiteralPath (Join-Path $temp2 '.statefulclanker\state.json') -Encoding UTF8
try {
    . (Join-Path $repo 'mcp\StatefulClanker.McpCore.ps1')
    $script:events2=@()
    function Add-SCEvent([string]$Type,$Message,$Data) { $script:events2 += ,[pscustomobject]@{type=$Type;message=$Message;data=$Data} }
    $script:mcpAddCalls=@()
    function Add-SCRpkLesson([string]$Title,[string]$Body,[string[]]$Tags=@(),[string[]]$Paths=@(),[string]$Source='worker',[double]$Confidence=.75) {
        $script:mcpAddCalls += ,[pscustomobject]@{title=$Title;body=$Body;tags=$Tags;paths=$Paths;source=$Source;confidence=$Confidence}
        return [pscustomobject]@{id='lesson-2';title=$Title}
    }
    $script:confirmCalls=@();function Confirm-SCRpkLesson([string]$Id,[string]$Note='') { $script:confirmCalls += ,[pscustomobject]@{id=$Id;note=$Note}; return [pscustomobject]@{id=$Id;status='confirmed'} }
    $script:rejectCalls=@();function Reject-SCRpkLesson([string]$Id,[string]$Note='') { $script:rejectCalls += ,[pscustomobject]@{id=$Id;note=$Note}; return [pscustomobject]@{id=$Id;status='rejected'} }
    function Search-SCRpkLessons([string]$Text,[string[]]$Paths=@(),[int]$Limit=8) { return @([pscustomobject]@{id='l1';status='needs_review'},[pscustomobject]@{id='l2';status='confirmed'}) }
    function Get-SCRpkStatus { return [pscustomobject]@{indexed=$true} }
    . (Join-Path $repo 'mcp\StatefulClanker.McpExtensions.ps1')

    $addArgs=[pscustomobject]@{project=$temp2;title='Lesson title';body='Lesson body';tags=@('a','b');paths=@();confidence=.9}
    $addResult=Invoke-SCExtendedTool 'rpk_lesson_add' $addArgs
    Assert-True ($script:mcpAddCalls.Count-eq1) 'rpk_lesson_add did not call Add-SCRpkLesson.'
    Assert-True ($script:mcpAddCalls[0].title-eq'Lesson title') 'rpk_lesson_add did not map title.'
    Assert-True ($script:mcpAddCalls[0].source-eq'control-plane') "rpk_lesson_add must use source='control-plane', got '$($script:mcpAddCalls[0].source)'."
    Assert-True (@($script:events2|Where-Object{$_.type-eq'rpk.lesson_recorded'}).Count-eq1) 'rpk.lesson_recorded event not emitted by MCP add.'

    $confirmResult=Invoke-SCExtendedTool 'rpk_lesson_confirm' ([pscustomobject]@{project=$temp2;id='l1';note='verified'})
    Assert-True ($script:confirmCalls.Count-eq1-and$script:confirmCalls[0].id-eq'l1') 'rpk_lesson_confirm did not map id/note.'
    Assert-True (@($script:events2|Where-Object{$_.type-eq'rpk.lesson_confirmed'}).Count-eq1) 'rpk.lesson_confirmed event not emitted.'

    $rejectResult=Invoke-SCExtendedTool 'rpk_lesson_reject' ([pscustomobject]@{project=$temp2;id='l2';note='stale'})
    Assert-True ($script:rejectCalls.Count-eq1-and$script:rejectCalls[0].id-eq'l2') 'rpk_lesson_reject did not map id/note.'
    Assert-True (@($script:events2|Where-Object{$_.type-eq'rpk.lesson_rejected'}).Count-eq1) 'rpk.lesson_rejected event not emitted.'

    $listResult=Invoke-SCExtendedTool 'rpk_lessons' ([pscustomobject]@{project=$temp2;text='q';status='needs_review'})
    $listPayload=$listResult.content[0].text|ConvertFrom-Json
    Assert-True (@($listPayload.lessons).Count-eq1-and$listPayload.lessons[0].id-eq'l1') 'rpk_lessons did not apply status filter.'

    $statusResult=Invoke-SCExtendedTool 'rpk_status' ([pscustomobject]@{project=$temp2})
    $statusPayload=$statusResult.content[0].text|ConvertFrom-Json
    Assert-True ([bool]$statusPayload.status.indexed) 'rpk_status did not return Get-SCRpkStatus output.'

    # RPK-unavailable path returns a clear tool error, not a crash.
    Remove-Item Function:\Add-SCRpkLesson -ErrorAction SilentlyContinue
    function Add-SCRpkLesson([string]$Title,[string]$Body,[string[]]$Tags=@(),[string[]]$Paths=@(),[string]$Source='worker',[double]$Confidence=.75) { throw 'RPK native host unavailable.' }
    $threw=$false
    try{[void](Invoke-SCExtendedTool 'rpk_lesson_add' ([pscustomobject]@{project=$temp2;title='t';body='b'}))}catch{$threw=$true;Assert-True ($_.Exception.Message-match'RPK unavailable') "Expected a clear RPK-unavailable error, got: $($_.Exception.Message)"}
    Assert-True $threw 'RPK-unavailable must surface as a clear tool error, not silently succeed.'

    Write-Host 'PASS: control-plane RPK lesson MCP tools (add/confirm/reject/list/status, events, unavailable-host error).'
} finally {
    Remove-Item -LiteralPath $temp2 -Recurse -Force -ErrorAction SilentlyContinue
}
