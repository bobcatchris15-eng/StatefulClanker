# Conversational-plane management for reusable machine capability profiles.
$script:SCBaseNewExtendedToolsProfiles=(Get-Item Function:\New-SCExtendedTools).ScriptBlock
$script:SCBaseInvokeExtendedToolProfiles=(Get-Item Function:\Invoke-SCExtendedTool).ScriptBlock
$script:SCBaseControlInstructionsProfiles=(Get-Item Function:\Get-SCControlPlaneInstructions).ScriptBlock

function Assert-McpProfileTightens($Profile,$Catalog) {
    if($null-eq$Profile){throw 'profile policy required'}
    if($Profile.PSObject.Properties['allow']-and$null-ne$Profile.allow){foreach($pattern in @($Profile.allow)){if(-not(Test-McpMachineCanGrantPattern ([string]$pattern) $Catalog)){throw "Capability profile cannot grant '$pattern'; machine policy does not allow it."}}}
}
function New-SCExtendedTools {
    $base=@(& $script:SCBaseNewExtendedToolsProfiles)
    $base+=@(
      @{name='worker_profile_set';description='Create/update a reusable machine worker capability profile. A profile may only narrow machine-authorized capabilities.';inputSchema=@{type='object';properties=@{project=@{type='string'};name=@{type='string'};profile=@{type='object'}};required=@('name','profile')}},
      @{name='worker_profile_remove';description='Remove a reusable machine worker capability profile. Tasks naming a removed profile will fail closed until updated.';inputSchema=@{type='object';properties=@{project=@{type='string'};name=@{type='string'}};required=@('name')}}
    );return $base
}
function Invoke-SCExtendedTool([string]$Name,$Arguments) {
    if(@('worker_profile_set','worker_profile_remove')-notcontains$Name){return & $script:SCBaseInvokeExtendedToolProfiles $Name $Arguments}
    $project=Get-McpProject $Arguments;Assert-McpInitialized $project;$catalog=Get-McpWorkerCatalog
    if(-not$catalog.PSObject.Properties['profiles']){$catalog|Add-Member profiles ([pscustomobject]@{}) -Force}
    switch($Name){
      'worker_profile_set' {
        $profileName=Get-McpArgRequired $Arguments 'name';if($profileName-notmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'Invalid capability profile name.'};if(-not$Arguments.PSObject.Properties['profile']){throw 'profile required'}
        $profile=$Arguments.profile;Assert-McpProfileTightens $profile $catalog;$catalog.profiles|Add-Member -NotePropertyName $profileName -NotePropertyValue $profile -Force;Write-McpWorkerJson (Get-McpWorkerMachinePolicyPath) $catalog;Add-McpWorkerAudit 'profile-set' @{name=$profileName;profile=$profile};return New-McpTextResult ([ordered]@{updated=$true;name=$profileName;profile=$profile})
      }
      'worker_profile_remove' {
        $profileName=Get-McpArgRequired $Arguments 'name';$prop=$catalog.profiles.PSObject.Properties[$profileName];if($prop){$catalog.profiles.PSObject.Properties.Remove($profileName);Write-McpWorkerJson (Get-McpWorkerMachinePolicyPath) $catalog};Add-McpWorkerAudit 'profile-remove' @{name=$profileName};return New-McpTextResult ([ordered]@{removed=[bool]$prop;name=$profileName})
      }
    }
}
function Get-SCControlPlaneInstructions {
    $base=& $script:SCBaseControlInstructionsProfiles
    return $base+@'

CAPABILITY PROFILES AND TASK NARROWING

Machine policy may define reusable named capability profiles. A task may select one with capabilityProfile / `capability-profile <name>` in SCPLAN. Profiles are narrowing layers only: they cannot grant capabilities outside the machine allow-list. Project, role, stage, and task-local policy may narrow further.

Use `tool-allow <pattern>` and `tool-deny <pattern>` in SCPLAN when one task needs a narrower set than its profile. Prefer named profiles for repeated policy and task-local rules for exceptional restrictions. Changing a task's capability profile or local tool policy changes the task definition hash and makes older work stale.
'@
}
