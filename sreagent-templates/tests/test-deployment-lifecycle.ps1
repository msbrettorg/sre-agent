$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$deploySource = Get-Content (Join-Path $root 'bin/ps/Deploy-Agent.ps1') -Raw
$bashDeploy = Get-Content (Join-Path $root 'bin/deploy.sh') -Raw
$terraformDeploy = Get-Content (Join-Path $root 'bin/deploy-tf.sh') -Raw

# Never execute a version that might recursively remove the system temp directory.
if ($deploySource -match '\$CleanupFiles\s*\+=.*Split-Path\s+\$AssembleTmp' -or
    $deploySource -match 'Remove-Item\s+\$f\s+-Recurse' -or
    $deploySource -notmatch '\$CleanupFiles\s*\+=\s*\$ParametersFile,\s*\$ExtrasFile') {
    throw 'Unsafe assembler cleanup: expected only the two owned output files.'
}
foreach ($source in @($bashDeploy, $terraformDeploy)) {
    $preflight = $source.IndexOf('pwsh -NoProfile -File "$EXTRAS_BRIDGE" -Preflight')
    $handoff = $source.IndexOf('pwsh -NoProfile -File "$EXTRAS_BRIDGE" "${EXTRAS_ARGS[@]}"')
    if ($preflight -lt 0 -or $handoff -le $preflight -or
        $source -match 'bash .*apply-extras\.sh') {
        throw 'Bash deployment entrypoint must preflight and invoke the native extras bridge.'
    }
}
if ($bashDeploy.IndexOf('pwsh -NoProfile -File "$EXTRAS_BRIDGE" -Preflight') -gt
    $bashDeploy.IndexOf('az deployment sub create') -or
    $terraformDeploy.IndexOf('pwsh -NoProfile -File "$EXTRAS_BRIDGE" -Preflight') -gt
    $terraformDeploy.IndexOf('terraform apply -input=false')) {
    throw 'The extras preflight must run before infrastructure writes.'
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "sre-lifecycle-$([guid]::NewGuid())"
$psDir = Join-Path $sandbox 'bin/ps'
$bicepDir = Join-Path $sandbox 'bicep'
$config = Join-Path $sandbox 'config'
New-Item -ItemType Directory -Path $psDir, $bicepDir, $config -Force | Out-Null
try {
    Copy-Item (Join-Path $root 'bin/ps/Invoke-DeploymentExtras.ps1') $psDir
    Copy-Item (Join-Path $root 'bin/ps/Deploy-Agent.ps1') $psDir
    Set-Content (Join-Path $psDir 'Check-Prerequisites.ps1') @'
function Test-Prerequisites { param([switch]$IncludePython, [switch]$IncludeTar)
    return ($env:SRE_TEST_PREREQS -ne 'missing')
}
'@
    Set-Content (Join-Path $bicepDir 'Apply-Extras.ps1') @'
param($Subscription, $ResourceGroup, $AgentName, $ExtrasFile, [switch]$Force, [switch]$RequireComplete)
if (-not $RequireComplete -or $Subscription -ne 'test-sub' -or $AgentName -ne 'test-agent' -or
    $ResourceGroup -ne 'test-rg' -or -not (Test-Path $ExtrasFile)) { throw 'Extras arguments incorrect' }
Add-Content $env:SRE_TEST_EVENTS "EXTRAS force=$Force"
if ($env:SRE_TEST_SCENARIO -eq 'ExtrasFail') { throw 'Mock extras failure' }
'@
    Set-Content (Join-Path $psDir 'Az-PowerShell.ps1') @'
function Get-RequiredAzContext { param($SubscriptionId)
    return [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $SubscriptionId; Name = 'test' } }
}
function Invoke-AzJsonRest { param($Method, $Uri, $DefaultProfile) return $null }
'@
    Set-Content (Join-Path $psDir 'Scope-Guard.ps1') @'
function Test-ScopeDrift { param($SubscriptionId, $ResourceGroup, $AgentName, $TargetResourceGroups, $AllowScopeLoss)
    return $true
}
'@
    Set-Content (Join-Path $bicepDir 'main.bicep') 'mock template'
    Set-Content (Join-Path $bicepDir 'Assemble-Agent.ps1') @'
param($ConfigDir, $Output)
$env:SRE_TEST_ASSEMBLED = $Output
Add-Content $env:SRE_TEST_EVENTS 'ASSEMBLE'
$names = 'location','agentName','agentResourceGroupName','targetResourceGroups',
    'accessLevel','actionMode','upgradeChannel','defaultModelProvider',
    'monthlyAgentUnitLimit','connectors','enableWebhookBridge',
    'enableLogAnalyticsConnector','enableAppInsightsConnector','enableAzureMonitorConnector',
    'skills','subagents'
$p = @{}
foreach ($name in $names) { $p[$name] = @{ value = '' } }
$p.location.value = 'eastus2'
$p.agentName.value = 'test-agent'
$p.agentResourceGroupName.value = 'test-rg'
$p.targetResourceGroups.value = @()
$p.connectors.value = @()
@{ parameters = $p } | ConvertTo-Json -Depth 12 | Set-Content "${Output}.parameters.json"
'{"skills":[{"name":"mock"}],"hooks":[],"commonPrompts":[],"incidentPlatforms":[],"incidentFilters":[],"scheduledTasks":[],"httpTriggers":[],"repos":[],"knowledgeItems":[],"knowledge":[]}' | Set-Content "${Output}.extras.json"
Add-Content $env:SRE_TEST_EVENTS "ASSEMBLED_PATH=$Output"
'@
    Set-Content (Join-Path $psDir 'Verify-Agent.ps1') @'
param($SubscriptionId, $ResourceGroup, $AgentName, $Expected)
Add-Content $env:SRE_TEST_EVENTS 'VERIFY'
if ($env:SRE_TEST_SCENARIO -eq 'VerifyFail') { exit 1 }
exit 0
'@
    Set-Content (Join-Path $config 'agent.json') '{"identity":{"subscription":"test-sub"}}'
    $mockFunctions = @'
function Get-AzContext { }
function Get-AzAccessToken { }
function Invoke-AzRestMethod { }
function New-AzSubscriptionDeployment {
    Add-Content $env:SRE_TEST_EVENTS 'ARM'
    return [pscustomobject]@{
        ProvisioningState = 'Succeeded'
        Outputs = [pscustomobject]@{
            agentPortalUrl = [pscustomobject]@{ Value = '' }
            resourceGroupPortalUrl = [pscustomobject]@{ Value = '' }
            agentDataPlaneUrl = [pscustomobject]@{ Value = '' }
            managedIdentityId = [pscustomobject]@{ Value = '' }
            agentId = [pscustomobject]@{ Value = '' }
        }
    }
}
function Get-AzResourceGroup { return $null }
try {
    & $env:SRE_TEST_DEPLOY -InputPath $env:SRE_TEST_CONFIG -NoTelemetry
    exit $LASTEXITCODE
} catch {
    Write-Error $_
    exit 1
}
'@
    $invoke = Join-Path $psDir 'Invoke-DeploymentExtras.ps1'
    $deploy = Join-Path $psDir 'Deploy-Agent.ps1'
    $extras = Join-Path $bicepDir 'Apply-Extras.ps1'
    $events = Join-Path $sandbox 'events.txt'
    $env:SRE_TEST_EVENTS = $events
    $env:SRE_TEST_PREREQS = ''
    $env:SRE_TEST_SCENARIO = ''
    $env:SRE_TEST_DEPLOY = $deploy
    $env:SRE_TEST_CONFIG = $config
    $extrasFile = Join-Path $sandbox 'input.extras.json'
    Set-Content $extrasFile '{"skills":[{"name":"mock"}]}'

    $out = (& pwsh -NoProfile -File $invoke -Preflight 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Bridge preflight failed: $out" }
    $env:SRE_TEST_PREREQS = 'missing'
    $out = (& pwsh -NoProfile -File $invoke -Preflight 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -or $out -notmatch 'prerequisites are missing') {
        throw "Missing prerequisites did not stop bridge: $out"
    }
    $env:SRE_TEST_PREREQS = ''

    foreach ($scenario in @('Success', 'ExtrasFail', 'VerifyFail', 'MissingApply', 'MissingVerify', 'MissingPrerequisite')) {
        $env:SRE_TEST_SCENARIO = $scenario
        Remove-Item $events -ErrorAction SilentlyContinue
        if ($scenario -eq 'MissingApply') { Rename-Item $extras 'Apply-Extras.ps1.disabled' }
        if ($scenario -eq 'MissingVerify') { Rename-Item (Join-Path $psDir 'Verify-Agent.ps1') 'Verify-Agent.ps1.disabled' }
        if ($scenario -eq 'MissingPrerequisite') { $env:SRE_TEST_PREREQS = 'missing' }
        $output = (& pwsh -NoProfile -Command $mockFunctions 2>&1 | Out-String)
        $status = $LASTEXITCODE
        $recorded = if (Test-Path $events) { @(Get-Content $events) } else { @() }
        $arm = @($recorded | Where-Object { $_ -eq 'ARM' }).Count
        $applied = @($recorded | Where-Object { $_ -like 'EXTRAS *' }).Count
        $verified = @($recorded | Where-Object { $_ -eq 'VERIFY' }).Count
        if ($scenario -eq 'MissingApply') { Rename-Item "$extras.disabled" 'Apply-Extras.ps1' }
        if ($scenario -eq 'MissingVerify') {
            Rename-Item (Join-Path $psDir 'Verify-Agent.ps1.disabled') 'Verify-Agent.ps1'
        }
        $env:SRE_TEST_PREREQS = ''
        $expected = switch ($scenario) {
            Success { @(0, 1, 1, 1) }
            ExtrasFail { @(1, 1, 1, 0) }
            VerifyFail { @(1, 1, 1, 1) }
            MissingApply { @(1, 0, 0, 0) }
            MissingVerify { @(1, 0, 0, 0) }
            MissingPrerequisite { @(1, 0, 0, 0) }
        }
        if ((@($status, $arm, $applied, $verified) -join ',') -ne ($expected -join ',')) {
            throw "$scenario handoff: exit/ARM/extras/verify=$status,$arm,$applied,$verified; $output"
        }
        if ($scenario -eq 'Success') {
            $assembled = ($recorded | Where-Object { $_ -like 'ASSEMBLED_PATH=*' }) -replace '^ASSEMBLED_PATH=', ''
            if ((Test-Path "${assembled}.parameters.json") -or (Test-Path "${assembled}.extras.json")) {
                throw 'Owned temporary assembly files were not cleaned.'
            }
        }
    }

    $env:SRE_TEST_SCENARIO = ''
    Remove-Item $events -ErrorAction SilentlyContinue
    $out = (& pwsh -NoProfile -File $invoke -Subscription test-sub -ResourceGroup test-rg `
        -AgentName test-agent -ExtrasFile $extrasFile -Force 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not ((Get-Content $events) -contains 'EXTRAS force=True')) {
        throw "Bridge did not forward -Force and extras arguments: $out"
    }
    Write-Host 'Offline deployment handoff, preflight, status, and cleanup regressions passed.'
} finally {
    Remove-Item Env:SRE_TEST_EVENTS, Env:SRE_TEST_PREREQS, Env:SRE_TEST_SCENARIO, `
        Env:SRE_TEST_DEPLOY, Env:SRE_TEST_CONFIG -ErrorAction SilentlyContinue
    Remove-Item $sandbox -Recurse -Force
}
