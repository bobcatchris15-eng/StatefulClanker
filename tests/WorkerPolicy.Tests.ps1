$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "WORKER POLICY TEST FAILED: $Message"}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('sc-worker-policy-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $temp|Out-Null
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $temp 'local';New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA|Out-Null
try {
    . (Join-Path $repo 'lib\StatefulClanker.Core.ps1');Set-SCRoots $temp $temp
    function Add-SCEvent { param($Type,$Message,$Data) }
    function Resolve-SCSourceReference { param([string]$SourceRef); if($SourceRef-eq'human:h-test'){return [pscustomobject]@{content='verbatim human intent'}}; return $null }
    function Get-SCIntentContract { return [pscustomobject]@{revision=7;objective='normalized objective';requirements=@('r1');constraints=@();invariants=@();nonGoals=@();decisions=@();preferences=@();openQuestions=@();successDefinition='done'} }
    function Get-SCIntentHash { param($Contract); return 'intent-hash-test' }
    function Get-SCCurrentDirectiveSnapshot { return [ordered]@{revision=3;hash='directive-hash';items=@([ordered]@{id='routing';text='use bounded workers'})} }
    . (Join-Path $repo 'lib\StatefulClanker.WorkerPolicy.ps1');function Invoke-SCProvider { throw 'CLI provider path not expected.' };. (Join-Path $repo 'lib\StatefulClanker.WorkerRuntime.ps1')

    $catalog=[ordered]@{
      schemaVersion=2;allow=@('builtin.*','intent.human.read','intent.normalized.read','mcp.toaster.search','mcp.toaster.read');deny=@('builtin.run_command')
      profiles=[ordered]@{research=[ordered]@{allow=@('builtin.read_file','intent.*','mcp.toaster.search');deny=@()}}
      sources=[ordered]@{toaster=[ordered]@{transport='http';url='http://127.0.0.1:9999/mcp';enabled=$true;tools=@(
        [ordered]@{name='search';description='Search toast';inputSchema=[ordered]@{type='object';properties=[ordered]@{q=[ordered]@{type='string'}};required=@('q')}},
        [ordered]@{name='read';description='Read toast';inputSchema=[ordered]@{type='object';properties=[ordered]@{id=[ordered]@{type='string'}};required=@('id')}},
        [ordered]@{name='write_lesson';description='Write toast';inputSchema=[ordered]@{type='object';properties=[ordered]@{text=[ordered]@{type='string'}};required=@('text')}}
      )}}
    }
    $catalog|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Get-SCWorkerPolicyMachinePath) -Encoding UTF8
    $policy=[ordered]@{schemaVersion=1;allow=@('builtin.*','intent.*','mcp.toaster.*');deny=@('builtin.write_file');roles=[ordered]@{critic=[ordered]@{allow=@('builtin.read_file','intent.*','mcp.toaster.search');deny=@()}};stages=[ordered]@{validator=[ordered]@{deny=@('mcp.*')}}}
    $policy|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Get-SCWorkerPolicyProjectPath) -Encoding UTF8

    $worker=[pscustomobject]@{id='t1';role='worker'}
    Assert-True (Test-SCWorkerCapabilityAllowed 'builtin.read_file' $worker 'worker') 'read_file should be allowed.'
    Assert-True (-not(Test-SCWorkerCapabilityAllowed 'builtin.run_command' $worker 'worker')) 'machine deny must win.'
    Assert-True (-not(Test-SCWorkerCapabilityAllowed 'builtin.write_file' $worker 'worker')) 'project deny must win.'
    Assert-True (Test-SCWorkerCapabilityAllowed 'intent.human.read' $worker 'worker') 'human intent reader should be allowed.'
    Assert-True (Test-SCWorkerCapabilityAllowed 'mcp.toaster.search' $worker 'worker') 'authorized Toaster search should be allowed.'
    Assert-True (-not(Test-SCWorkerCapabilityAllowed 'mcp.toaster.write_lesson' $worker 'worker')) 'machine catalog must not implicitly grant undeclared write tool.'

    $profiled=[pscustomobject]@{id='t-profile';role='worker';capabilityProfile='research'}
    Assert-True (Test-SCWorkerCapabilityAllowed 'builtin.read_file' $profiled 'worker') 'profile should retain read_file.'
    Assert-True (Test-SCWorkerCapabilityAllowed 'mcp.toaster.search' $profiled 'worker') 'profile should retain Toaster search.'
    Assert-True (-not(Test-SCWorkerCapabilityAllowed 'mcp.toaster.read' $profiled 'worker')) 'profile explicit allow must narrow Toaster read.'
    Assert-True (-not(Test-SCWorkerCapabilityAllowed 'builtin.write_file' $profiled 'worker')) 'profile must not restore project-denied write access.'
    $taskNarrow=[pscustomobject]@{id='t-narrow';role='worker';capabilityProfile='research';toolPolicy=[pscustomobject]@{allow=$null;deny=@('mcp.toaster.search')}}
    Assert-True (-not(Test-SCWorkerCapabilityAllowed 'mcp.toaster.search' $taskNarrow 'worker')) 'task-local deny must narrow a profile.'
    $unknownThrew=$false;try{[void](Test-SCWorkerCapabilityAllowed 'builtin.read_file' ([pscustomobject]@{id='bad';role='worker';capabilityProfile='missing'}) 'worker')}catch{$unknownThrew=$true};Assert-True $unknownThrew 'Unknown profiles must fail closed.'

    $critic=[pscustomobject]@{id='t2';role='critic'}
    Assert-True (Test-SCWorkerCapabilityAllowed 'mcp.toaster.search' $critic 'critic') 'critic role should retain Toaster search.'
    Assert-True (-not(Test-SCWorkerCapabilityAllowed 'mcp.toaster.read' $critic 'critic')) 'critic explicit allow must narrow Toaster read.'
    Assert-True (-not(Test-SCWorkerCapabilityAllowed 'mcp.toaster.search' $worker 'validator')) 'validator stage deny must remove all MCP tools.'

    $external=@(Get-SCExternalWorkerToolRecords $worker 'worker');Assert-True ($external.Count-eq2) 'Only the two machine-authorized Toaster tools should be advertised.';Assert-True (@($external.capability)-contains'mcp.toaster.search') 'Toaster search missing from advertised records.';Assert-True (@($external.capability)-notcontains'mcp.toaster.write_lesson') 'Unauthorized write_lesson was advertised.'
    $profileExternal=@(Get-SCExternalWorkerToolRecords $profiled 'worker');Assert-True ($profileExternal.Count-eq1-and$profileExternal[0].capability-eq'mcp.toaster.search') 'Profile did not narrow advertised external tools.'

    $registry=@(Get-SCWorkerToolRecords $worker 'worker');$human=$registry|Where-Object wireName -eq'read_human_intent';$normalized=$registry|Where-Object wireName -eq'read_normalized_intent';Assert-True ($null-ne$human) 'Human intent reader was not advertised.';Assert-True ($null-ne$normalized) 'Normalized intent reader was not advertised.'
    $humanResult=Invoke-SCWorkerTool 'read_human_intent' ([pscustomobject]@{sourceRef='human:h-test'}) $worker 'worker' $registry;Assert-True ($humanResult -match 'verbatim human intent') 'Human reader did not return direct source evidence.'
    $normalizedResult=Invoke-SCWorkerTool 'read_normalized_intent' ([pscustomobject]@{}) $worker 'worker' $registry;Assert-True ($normalizedResult -match 'normalized objective' -and $normalizedResult -match 'use bounded workers') 'Normalized reader did not return Intent plus current directives.'
    Write-Host 'PASS: worker capability policy, profiles, and task-local narrowing are tighten-only.'
} finally {$env:LOCALAPPDATA=$oldLocal;Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
