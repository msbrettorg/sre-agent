<#
.SYNOPSIS
    Deploy an SRE Agent via Bicep.

.DESCRIPTION
    Accepts either:
      (a) A config directory (agent.json + connectors.json + config/*.yaml)
          → runs Assemble-Agent.ps1 internally, then deploys
      (b) A legacy .parameters.json file → deploys directly

    After deploy, auto-runs Apply-Extras.ps1 for data-plane config (repos, hooks, etc.)

.PARAMETER InputPath
    Config directory or legacy .parameters.json file.

.PARAMETER DeploymentName
    Optional ARM deployment name. Defaults to sre-agent-<timestamp>.

.PARAMETER DryRun
    Assemble only, no ARM call.

.PARAMETER WhatIf
    ARM validation without deploying.

.PARAMETER Force
    Redeploy even if no changes detected.

.PARAMETER NoTelemetry
    Disable anonymous telemetry.

.EXAMPLE
    .\Deploy-Agent.ps1 -InputPath C:\config\myagent
    .\Deploy-Agent.ps1 -InputPath C:\config\myagent -DryRun
    .\Deploy-Agent.ps1 -InputPath .\params.json -Force
#>
[CmdletBinding(SupportsShouldProcess = $false)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$DeploymentName,

    [switch]$DryRun,

    [switch]$WhatIf_,  # renamed to avoid collision with built-in $WhatIfPreference

    [switch]$Force,

    [switch]$NoTelemetry
)

# Also accept -WhatIf as a named alias from the command line
# PowerShell reserves -WhatIf for SupportsShouldProcess, so we use -WhatIf_ internally
# but also check $PSBoundParameters for a raw --WhatIf passed via CLI
if ($args -contains '--WhatIf' -or $args -contains '-WhatIf') {
    $WhatIf_ = $true
}

Set-StrictMode -Version Latest

# PS 7.3+ changed how native-command arguments are passed; use Legacy to avoid
# broken arg splitting when args contain '=' (e.g. jq --argjson, terraform -out=).
if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 3) {
    $PSNativeCommandArgumentPassing = 'Legacy'
}
$ErrorActionPreference = 'Stop'

# ── Prereqs ──
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptDir 'Check-Prerequisites.ps1')
if (-not (Test-Prerequisites -IncludePython)) { exit 1 }
$AzPowerShellPath = Join-Path $ScriptDir 'Az-PowerShell.ps1'
. $AzPowerShellPath

# ── Resolve paths ──
$BinDir = Split-Path -Parent $ScriptDir   # bin/ps -> bin
$BicepDir = Join-Path (Split-Path -Parent $BinDir) 'bicep'
$Template = Join-Path $BicepDir 'main.bicep'

# Source telemetry
$TelemetryScript = Join-Path $ScriptDir 'Telemetry.ps1'
if (Test-Path $TelemetryScript) {
    . $TelemetryScript
}

# ── Helpers ──
function Write-Header([string]$Text) {
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Success([string]$Text) {
    Write-Host $Text -ForegroundColor Green
}

function Write-Fail([string]$Text) {
    Write-Host $Text -ForegroundColor Red
}

function Get-JsonValue {
    param([string]$Json, [string]$Query, [string]$Default = '')
    try {
        $result = $Json | ConvertFrom-Json
        $parts = $Query -split '\.'
        $current = $result
        foreach ($part in $parts) {
            if ($null -eq $current) { return $Default }
            $current = $current.$part
        }
        if ($null -eq $current -or $current -eq '') { return $Default }
        return $current
    } catch {
        return $Default
    }
}

# ── Validate prerequisites ──
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    Write-Fail 'Error: jq is required but not found.'
    exit 1
}

# ── Resolve input ──
$resolved = Resolve-Path $InputPath -ErrorAction SilentlyContinue
$InputPath = if ($resolved) { $resolved.Path } else { $InputPath }
if (-not (Test-Path $InputPath)) {
    Write-Fail "Error: input path '$InputPath' not found."
    exit 1
}

if (-not $DeploymentName) {
    $DeploymentName = "sre-agent-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

if (-not (Test-Path $Template)) {
    Write-Fail "Error: Bicep template not found at $Template"
    exit 1
}

# ── Detect input type and resolve to parameters.json ──
$CleanupFiles = @()
$ExtrasFile = ''
$IsDirectory = Test-Path $InputPath -PathType Container

if ($IsDirectory) {
    $AgentJson = Join-Path $InputPath 'agent.json'
    if (-not (Test-Path $AgentJson)) {
        Write-Fail "Error: $AgentJson not found"
        exit 1
    }

    Write-Header "── Assembling from directory: $InputPath/ ──"

    $AssembleScript = Join-Path $BicepDir 'Assemble-Agent.ps1'
    if (-not (Test-Path $AssembleScript)) {
        Write-Fail "Error: PowerShell assembler not found at $AssembleScript"
        exit 1
    }

    $AssembleTmp = Join-Path ([System.IO.Path]::GetTempPath()) "assembled-$(New-Guid)"
    $AssembleOut = $AssembleTmp

    & $AssembleScript -ConfigDir $InputPath -Output $AssembleOut

    $ParametersFile = "${AssembleOut}.parameters.json"
    $ExtrasFile = "${AssembleOut}.extras.json"
    $CleanupFiles += $ParametersFile, $ExtrasFile, (Split-Path $AssembleTmp -Parent)

    # Copy extras.json into InputPath so it survives cleanup and can be re-used
    # (e.g. re-running Apply-Extras standalone without a full re-deploy)
    $AgentNameForExtras = (Get-Item $InputPath).Name
    $PersistedExtras = Join-Path $InputPath "${AgentNameForExtras}.extras.json"
    Copy-Item $ExtrasFile $PersistedExtras -Force

    Write-Host ''
} elseif (Test-Path $InputPath -PathType Leaf) {
    $ParametersFile = $InputPath
    $ExtrasFile = ''
} else {
    Write-Fail "Error: $InputPath not found (expected directory or .json file)"
    exit 1
}

if (-not (Test-Path $ParametersFile)) {
    Write-Fail "Error: parameters file not found: $ParametersFile"
    exit 1
}

# ── Pre-flight: parse params and show summary ──
$ParamsRaw = Get-Content $ParametersFile -Raw
$Params = $ParamsRaw | ConvertFrom-Json

function Get-Param([string]$Name, $Default = $null) {
    $val = $Params.parameters.$Name.value
    if ($null -eq $val -or $val -eq '') { return $Default }
    return $val
}

$Location    = Get-Param 'location' 'eastus2'
$AgentName   = Get-Param 'agentName'
$ResourceGroup = Get-Param 'agentResourceGroupName'
$TargetRGs   = Get-Param 'targetResourceGroups'
$AccessLevel = Get-Param 'accessLevel' 'Low'
$ActionMode  = Get-Param 'actionMode' 'Review'
$UpgradeChannel = Get-Param 'upgradeChannel' 'Preview'
$ModelProvider  = Get-Param 'defaultModelProvider' 'Anthropic'
$MonthlyLimit   = Get-Param 'monthlyAgentUnitLimit' 10000

$RequestedSubscriptionId = if ($IsDirectory) {
    (Get-Content (Join-Path $InputPath 'agent.json') -Raw | ConvertFrom-Json).identity.subscription
} else {
    (Get-AzContext).Subscription.Id
}
if (-not $RequestedSubscriptionId) {
    Write-Fail 'Error: agent.json must specify identity.subscription.'
    exit 1
}
$AzContext = Get-RequiredAzContext -SubscriptionId $RequestedSubscriptionId
$SubscriptionId = $AzContext.Subscription.Id
$SubscriptionName = $AzContext.Subscription.Name

$RgExists = $null -ne (Get-AzResourceGroup -Name $ResourceGroup -DefaultProfile $AzContext -ErrorAction SilentlyContinue)
$RgStatus = if ($RgExists) { '(exists)' } else { '(will be created)' }
$TargetRGsStr = if ($TargetRGs -is [array]) { $TargetRGs -join ', ' } else { $TargetRGs }
if (-not $TargetRGsStr) { $TargetRGsStr = '<none>' }

Write-Host ''
Write-Header '──────────────── SRE Agent deployment ────────────────'
Write-Host "  Subscription:  $SubscriptionName ($SubscriptionId)"
Write-Host "  Region:        $Location"
Write-Host "  Agent name:    $AgentName"
Write-Host "  Agent RG:      $ResourceGroup  $RgStatus"
Write-Host "  Target RGs:    $TargetRGsStr"
Write-Host "  Access level:  $AccessLevel"
Write-Host "  Action mode:   $ActionMode"
Write-Host "  Upgrade chan:  $UpgradeChannel"
Write-Host "  Model:         $ModelProvider"
Write-Host "  Monthly limit: $MonthlyLimit AU"
Write-Host ''

# Show Bicep resources
Write-Host '  Bicep (ARM) resources:'

$WebhookBridge = Get-Param 'enableWebhookBridge' $false
if ($WebhookBridge -eq $true) {
    Write-Host '    ✓ Webhook bridge (Logic App)'
}

foreach ($toggle in @('enableLogAnalyticsConnector', 'enableAppInsightsConnector', 'enableAzureMonitorConnector')) {
    $val = Get-Param $toggle $false
    if ($val -eq $true) {
        switch ($toggle) {
            'enableLogAnalyticsConnector' { Write-Host '    ✓ Log Analytics connector' }
            'enableAppInsightsConnector'  { Write-Host '    ✓ App Insights connector' }
            'enableAzureMonitorConnector' { Write-Host '    ✓ Azure Monitor connector' }
        }
    }
}

# Array connectors
$Connectors = Get-Param 'connectors'
if (@($Connectors).Count -gt 0) {
    foreach ($c in $Connectors) {
        $cType = $c.properties.dataConnectorType
        Write-Host "    ✓ Connector: $($c.name) ($cType)"
    }
}

# Skills + subagents
foreach ($arr in @('skills', 'subagents')) {
    $items = Get-Param $arr
    if ($items -and $items.Count -gt 0) {
        Write-Host "    ✓ ${arr}: $($items.Count)"
    }
}

Write-Host ''
Write-Host '  Data-plane (apply-extras):'

# Resolve extras file
if (-not $ExtrasFile -or -not (Test-Path $ExtrasFile -ErrorAction SilentlyContinue)) {
    $candidate = $ParametersFile -replace '\.parameters\.json$', '.extras.json'
    if (Test-Path $candidate -ErrorAction SilentlyContinue) {
        $ExtrasFile = $candidate
    } else {
        $candidate2 = Join-Path (Split-Path $ParametersFile) 'assembled.extras.json'
        if (Test-Path $candidate2 -ErrorAction SilentlyContinue) {
            $ExtrasFile = $candidate2
        }
    }
}

if ($ExtrasFile -and (Test-Path $ExtrasFile -ErrorAction SilentlyContinue)) {
    $ExtrasRaw = Get-Content $ExtrasFile -Raw | ConvertFrom-Json
    $ExtrasKeys = @{
        hooks             = 'Hooks'
        commonPrompts     = 'Common prompts'
        incidentPlatforms = 'Incident platforms'
        incidentFilters   = 'Incident filters (response plans)'
        scheduledTasks    = 'Scheduled tasks'
        httpTriggers      = 'HTTP triggers'
        repos             = 'Repos'
        knowledgeItems    = 'Knowledge files'
        knowledge         = 'Knowledge docs'
    }
    foreach ($key in $ExtrasKeys.Keys) {
        $items = $ExtrasRaw.$key
        if ($items -and $items.Count -gt 0) {
            Write-Host "    ✓ $($ExtrasKeys[$key]): $($items.Count)"
        }
    }
} else {
    Write-Host '    (extras file not found — data-plane items shown in change detection below)'
}

Write-Host ''
Write-Host "  Deployment name: $DeploymentName"
Write-Header '─────────────────────────────────────────────────────'
Write-Host ''

# ── Pre-deploy: change detection ──
$ChangesDetected = ''
if ($IsDirectory) {
    Write-Header '── Change detection ──'

    $DiffScript = Join-Path $ScriptDir 'Diff-Agent.ps1'
    if (Test-Path $DiffScript) {
        try {
            & $DiffScript -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AgentName $AgentName -InputPath $InputPath
            $DiffExit = $LASTEXITCODE
        } catch {
            $DiffExit = 1
        }

        if ($DiffExit -eq 0) {
            Write-Host '  No changes detected.'
            if (-not $Force) {
                Write-Host '  Skipping deployment. Use -Force to redeploy anyway.'
                Write-Host ''

                # Still run verify
                $VerifyScript = Join-Path $ScriptDir 'Verify-Agent.ps1'
                if (Test-Path $VerifyScript) {
                    Write-Header '── Current state verification ──'
                    try {
                        & $VerifyScript -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AgentName $AgentName -Expected $InputPath
                    } catch { }
                }
                exit 0
            } else {
                Write-Host '  -Force: redeploying anyway.'
            }
        } elseif ($DiffExit -eq 2) {
            $ChangesDetected = 'new'
        } else {
            $ChangesDetected = 'update'
        }
    } else {
        Write-Host '  (Diff-Agent.ps1 not found — skipping change detection)'
    }
    Write-Host ''
}

# ── Dry-run: stop here ──
if ($DryRun) {
    Write-Header '── DRY RUN — no deployment performed ──'
    Write-Host '  Assemble: ✅ (parameters + extras built)'
    Write-Host '  To validate against ARM without deploying: -WhatIf_'
    Write-Host '  To deploy for real: remove -DryRun'
    exit 0
}

# ── What-if: validate against ARM without deploying ──
if ($WhatIf_) {
    Write-Header '── What-if validation (ARM preflight) ──'
    Write-Host ''

    try {
        $whatIfResult = New-AzSubscriptionDeployment -Name $DeploymentName `
            -Location $Location -TemplateFile $Template `
            -TemplateParameterFile $ParametersFile -DefaultProfile $AzContext -WhatIf
        Write-Host ($whatIfResult | Out-String)
        Write-Host ''
        Write-Success '✅ What-if passed — deployment should succeed.'
        exit 0
    } catch {
        Write-Host ''
        Write-Fail '❌ What-if found errors — fix before deploying.'
        Write-Fail $_.Exception.Message
        exit 1
    }
}

# ── Pre-deploy: auto-create VNet subnet with delegation if networkConfiguration.type=vnet ──
if ($IsDirectory) {
    $AgentJsonFile = Join-Path $InputPath 'agent.json'
    if (Test-Path $AgentJsonFile) {
        $agentCfg = Get-Content $AgentJsonFile -Raw | ConvertFrom-Json
        $netType = if ($agentCfg.PSObject.Properties['networkConfiguration'] -and $agentCfg.networkConfiguration.type) {
            $agentCfg.networkConfiguration.type.ToLower()
        } else { 'unrestricted' }

        if ($netType -eq 'vnet' -or $netType -eq 'azurevnet') {
            $netCfg = $agentCfg.networkConfiguration
            $netSubnetId = if ($netCfg.subnetId) { $netCfg.subnetId } else { '' }
            $netRg = if ($netCfg.resourceGroup) { $netCfg.resourceGroup } else { '' }
            $netVnet = if ($netCfg.vnetName) { $netCfg.vnetName } else { '' }
            $netSubnetName = if ($netCfg.subnetName) { $netCfg.subnetName } else { 'agent-subnet' }
            $netSubnetPrefix = if ($netCfg.subnetPrefix) { $netCfg.subnetPrefix } else { '10.2.0.0/28' }

            # Resolve subnet ID from broken-out fields if not given directly
            if (-not $netSubnetId -and $netVnet -and $netRg) {
                $netSubnetId = "/subscriptions/$SubscriptionId/resourceGroups/$netRg/providers/Microsoft.Network/virtualNetworks/$netVnet/subnets/$netSubnetName"
            }

            if ($netSubnetId) {
                # Extract components from subnet ID
                $parts = $netSubnetId -split '/'
                $vnetRgIdx = [array]::IndexOf($parts, 'resourceGroups') + 1
                $vnetIdx = [array]::IndexOf($parts, 'virtualNetworks') + 1
                $subnetIdx = [array]::IndexOf($parts, 'subnets') + 1
                $_vnet_rg = $parts[$vnetRgIdx]
                $_vnet_name = $parts[$vnetIdx]
                $_subnet_name = $parts[$subnetIdx]

                $vnet = Get-AzVirtualNetwork -ResourceGroupName $_vnet_rg `
                    -Name $_vnet_name -DefaultProfile $AzContext
                $subnet = Get-AzVirtualNetworkSubnetConfig -Name $_subnet_name `
                    -VirtualNetwork $vnet -ErrorAction SilentlyContinue
                $delegation = New-AzDelegation -Name 'Microsoft.App.environments' `
                    -ServiceName 'Microsoft.App/environments'
                if (-not $subnet) {
                    Write-Header "── Creating VNet subnet with Microsoft.App/environments delegation ──"
                    Write-Host "  VNet: $_vnet_name  Subnet: $_subnet_name  Prefix: $netSubnetPrefix"
                    $null = Add-AzVirtualNetworkSubnetConfig -Name $_subnet_name `
                        -VirtualNetwork $vnet -AddressPrefix $netSubnetPrefix `
                        -Delegation $delegation
                    $null = Set-AzVirtualNetwork -VirtualNetwork $vnet -DefaultProfile $AzContext
                    Write-Host '  ✅ Subnet created'
                } else {
                    $hasDelegation = @($subnet.Delegations).ServiceName -contains 'Microsoft.App/environments'
                    if (-not $hasDelegation) {
                        Write-Host "  ⚠ Subnet $_subnet_name exists but missing Microsoft.App/environments delegation"
                        Write-Host '    Adding delegation...'
                        $null = Set-AzVirtualNetworkSubnetConfig -Name $_subnet_name `
                            -VirtualNetwork $vnet -AddressPrefix $subnet.AddressPrefix `
                            -Delegation $delegation
                        $null = Set-AzVirtualNetwork -VirtualNetwork $vnet -DefaultProfile $AzContext
                    } else {
                        Write-Host "  VNet subnet $_subnet_name ready (delegation: Microsoft.App/environments)"
                    }
                }
            }
        }
    }
}

# ── Auto-detect redeploy: skip role assignments to avoid RoleAssignmentExists ──
$SkipRbacParam = ''
$agentResourceUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName`?api-version=2026-01-01"
try {
    $agentExistsCheck = Invoke-AzJsonRest -Method GET -Uri $agentResourceUri -DefaultProfile $AzContext
} catch {
    $agentExistsCheck = $null
}
if ($null -ne $agentExistsCheck) {
    Write-Host "  Agent '$AgentName' already exists — skipping role assignments on redeploy."
    $SkipRbacParam = 'skipRoleAssignments=true'
}

# ── Run the deployment ──
Write-Host 'Starting deployment (this typically takes 3-5 min)...'
Write-Host ''

try {
    $deploymentParameters = @{
        Name                  = $DeploymentName
        Location              = $Location
        TemplateFile          = $Template
        TemplateParameterFile = $ParametersFile
        DefaultProfile        = $AzContext
        ErrorAction           = 'Stop'
    }
    if ($SkipRbacParam) {
        $deploymentParameters.skipRoleAssignments = $true
    }
    $deployResult = New-AzSubscriptionDeployment @deploymentParameters
    Write-Host ($deployResult | Format-List | Out-String)
} catch {
    $deployResult = $null
    $deploymentError = $_
}

$State = 'Failed'
if ($deployResult) {
    $State = if ($deployResult.ProvisioningState) { $deployResult.ProvisioningState } else { 'Failed' }
}

if ($State -ne 'Succeeded') {
    Write-Host ''
    Write-Fail '══════════ Deployment FAILED ══════════'

    if ($deploymentError) {
        Write-Host "  Root cause: $($deploymentError.Exception.Message)"
    }
    Write-Host ''
    exit 1
}

Write-Host ''
Write-Header '─────────────── Deployment Succeeded ───────────────'
$portalUrl       = $deployResult.Outputs.agentPortalUrl.Value
$rgPortalUrl     = $deployResult.Outputs.resourceGroupPortalUrl.Value
$dataPlaneUrl    = $deployResult.Outputs.agentDataPlaneUrl.Value
Write-Host "  Agent (portal):  $portalUrl"
Write-Host "  Resource group:  $rgPortalUrl"
Write-Host "  Data plane:      $dataPlaneUrl"
Write-Host ''

# ── Telemetry ──
$RecipeName = 'unknown'
if ($IsDirectory) {
    $agentJsonPath = Join-Path $InputPath 'agent.json'
    if (Test-Path $agentJsonPath) {
        try {
            $agentCfg = Get-Content $agentJsonPath -Raw | ConvertFrom-Json
            $scenarioVal = if ($agentCfg.PSObject.Properties['_scenario']) { $agentCfg._scenario } else { $null }
            if ($scenarioVal) { $RecipeName = $scenarioVal } else { $RecipeName = 'custom' }
        } catch { }
    }
}

if (-not $NoTelemetry -and (Get-Command Send-Telemetry -ErrorAction SilentlyContinue)) {
    Send-Telemetry -Action 'deploy' -Recipe $RecipeName -Region $Location
}

# ── Auto-run Apply-Extras if extras file exists ──
if ($ExtrasFile -and (Test-Path $ExtrasFile -ErrorAction SilentlyContinue)) {
    $ExtrasContent = Get-Content $ExtrasFile -Raw | ConvertFrom-Json
    # Count non-empty data-plane entries
    $extrasCount = 0
    foreach ($prop in $ExtrasContent.PSObject.Properties) {
        if ($prop.Name -eq '_exported_from') { continue }
        $v = $prop.Value
        if ($null -eq $v) { continue }
        $isNonEmpty = $false
        if ($v -is [System.Array]) {
            $isNonEmpty = ($v.Length -gt 0)
        } elseif ($v -is [System.Collections.IList]) {
            $isNonEmpty = ($v.Count -gt 0)
        } elseif ($v -is [PSCustomObject]) {
            $isNonEmpty = (@($v.PSObject.Properties).Count -gt 0)
        } elseif ($v -is [string]) {
            $isNonEmpty = ($v.Length -gt 0)
        }
        if ($isNonEmpty) { $extrasCount++ }
    }

    if ($extrasCount -gt 0) {
        Write-Header '── Applying data-plane config (extras) ──'
        $ApplyExtrasScript = Join-Path $BicepDir 'Apply-Extras.ps1'
        if (Test-Path $ApplyExtrasScript) {
            $applyParams = @{
                Subscription  = $SubscriptionId
                ResourceGroup = $ResourceGroup
                AgentName     = $AgentName
                ExtrasFile    = $ExtrasFile
            }
            if ($Force) { $applyParams['Force'] = $true }
            & $ApplyExtrasScript @applyParams
        } else {
            throw "Apply-Extras.ps1 not found at $ApplyExtrasScript"
        }
    } else {
        Write-Host 'No data-plane extras to apply.'
    }
} else {
    Write-Host 'Next: apply data-plane config (repos, hooks, knowledge, GitHub/ADO auth):'
    Write-Host "  .\Apply-Extras.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AgentName $AgentName -ExtrasFile <extras-file>"
}

Write-Header '─────────────────────────────────────────────────────'

# ── Deployment log ──
$LogDir = if ($IsDirectory) { $InputPath } else { Split-Path $InputPath }
$DeployLog = Join-Path $LogDir "deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$Duration = if ($deployResult -and $deployResult.PSObject.Properties['Duration'] -and $deployResult.Duration) { $deployResult.Duration } else { '?' }

try {
    @"
Deployment: $DeploymentName
Timestamp:  $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)
Agent:      $AgentName
RG:         $ResourceGroup
Region:     $Location
State:      $State
Duration:   $Duration
Portal:     $portalUrl

"@ | Out-File -FilePath $DeployLog -Encoding utf8
} catch { }

# ── Post-deploy verification ──
if ($IsDirectory) {
    Write-Host ''
    Write-Header '── Post-deploy verification ──'
    $VerifyScript = Join-Path $ScriptDir 'Verify-Agent.ps1'
    $VerifyOutput = ''
    if (Test-Path $VerifyScript) {
        try {
            $VerifyOutput = & $VerifyScript -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AgentName $AgentName -Expected $InputPath 2>&1 | Out-String
        } catch {
            $VerifyOutput = $_.Exception.Message
        }
    } else {
        $VerifyOutput = "(Verify-Agent.ps1 not found at $VerifyScript)"
    }
    Write-Host $VerifyOutput

    # Append verify results to log
    try {
        @"

── Verification Results ──
$VerifyOutput

"@ | Out-File -FilePath $DeployLog -Append -Encoding utf8
    } catch { }

    Write-Host ''
    Write-Host "  Log saved: $DeployLog"
}

# ── Post-deploy: process roles.yaml if present ──
$RolesFile = ''
if ($IsDirectory) {
    $candidate = Join-Path $InputPath 'roles.yaml'
    if (Test-Path $candidate) {
        $RolesFile = $candidate
    } else {
        $candidate2 = Join-Path (Split-Path $InputPath) 'roles.yaml'
        if (Test-Path $candidate2) {
            $RolesFile = $candidate2
        }
    }
}

$UamiId = $null
$UamiPrincipal = ''
$AgentId = $null
$AgentSystemPrincipal = ''
try {
    $UamiId = $deployResult.Outputs.managedIdentityId.Value
    if ($UamiId) {
        $uamiResource = Invoke-AzJsonRest -Method GET `
            -Uri "https://management.azure.com${UamiId}?api-version=2023-01-31" `
            -DefaultProfile $AzContext
        $UamiPrincipal = $uamiResource.properties.principalId
    }
    $AgentId = $deployResult.Outputs.agentId.Value
    if ($AgentId) {
        $agentResource = Invoke-AzJsonRest -Method GET `
            -Uri "https://management.azure.com${AgentId}?api-version=2026-01-01" `
            -DefaultProfile $AzContext
        $AgentSystemPrincipal = $agentResource.identity.principalId
    }
} catch { }

if ($RolesFile -and (Test-Path $RolesFile)) {
    Write-Host ''
    Write-Header '── Setting up roles with Az PowerShell (from roles.yaml) ──'
    $rolesJson = python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1])) or {}))' $RolesFile
    if ($LASTEXITCODE -ne 0) {
        throw "Could not parse roles file: $RolesFile"
    }
    $roleConfig = $rolesJson | ConvertFrom-Json
    foreach ($role in @($roleConfig.roles)) {
        switch ($role.type) {
            'azure-role' {
                if (-not $UamiPrincipal) {
                    throw "UAMI principal ID is required for Azure role '$($role.name)'"
                }
                $existingRole = Get-AzRoleAssignment -ObjectId $UamiPrincipal -Scope $role.scope `
                    -RoleDefinitionId $role.role_definition_id -DefaultProfile $AzContext -ErrorAction SilentlyContinue
                if (-not $existingRole) {
                    $null = New-AzRoleAssignment -ObjectId $UamiPrincipal `
                        -RoleDefinitionId $role.role_definition_id -Scope $role.scope `
                        -DefaultProfile $AzContext
                }
                Write-Host "  ok Azure role: $($role.name)"
            }
            'adx-principal' {
                $principalId = if ($role.principal -eq 'agent-system') {
                    $AgentSystemPrincipal
                } else {
                    $UamiPrincipal
                }
                if (-not $principalId) {
                    throw "Principal ID is required for ADX role '$($role.name)'"
                }
                $scopeUri = [uri]$role.scope
                $clusterName = $scopeUri.Host.Split('.')[0]
                $cluster = Get-AzKustoCluster -DefaultProfile $AzContext |
                    Where-Object { $_.Name -eq $clusterName } |
                    Select-Object -First 1
                if (-not $cluster) {
                    throw "Kusto cluster '$clusterName' was not found in subscription $SubscriptionId"
                }
                $clusterResourceGroup = if ($cluster.Id -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { $null }
                if (-not $clusterResourceGroup) {
                    throw "Could not determine resource group for Kusto cluster '$clusterName' from Id '$($cluster.Id)'"
                }
                $assignmentName = "sre-agent-$AgentName-$($role.assignment_name)-$($principalId.Substring(0, 8))"
                $existingAssignment = Get-AzKustoClusterPrincipalAssignment `
                    -ResourceGroupName $clusterResourceGroup -ClusterName $cluster.Name `
                    -PrincipalAssignmentName $assignmentName -DefaultProfile $AzContext `
                    -ErrorAction SilentlyContinue
                if (-not $existingAssignment) {
                    $null = New-AzKustoClusterPrincipalAssignment `
                        -ResourceGroupName $clusterResourceGroup -ClusterName $cluster.Name `
                        -PrincipalAssignmentName $assignmentName -PrincipalId $principalId `
                        -PrincipalType App -Role $role.role -DefaultProfile $AzContext
                }
                Write-Host "  ok ADX role: $($role.name)"
            }
            'token' {
                Write-Host "  token required: $($role.name)"
            }
            'manual' {
                Write-Host "  manual setup required: $($role.name)"
            }
            default {
                throw "Unsupported PowerShell role type '$($role.type)' in $RolesFile"
            }
        }
    }
    $RolesFile = ''
}

# ── Recipe-specific post-deploy instructions ──
if ($IsDirectory) {
    $agentJsonPath = Join-Path $InputPath 'agent.json'
    if (Test-Path $agentJsonPath) {
        $agentCfg = Get-Content $agentJsonPath -Raw | ConvertFrom-Json
        $Scenario = if ($agentCfg.PSObject.Properties['_scenario']) { $agentCfg._scenario } else { $null }
        $WhEnabled = $false
        if ($agentCfg.PSObject.Properties['toggles'] -and $agentCfg.toggles -and $agentCfg.toggles.PSObject.Properties['enableWebhookBridge']) {
            $WhEnabled = [bool]$agentCfg.toggles.enableWebhookBridge
        }

        switch ($Scenario) {
            'dynatrace-mcp' {
                # Try to get the Logic App callback URL
                $WhCallback = ''
                try {
                    $callback = Invoke-AzJsonRest -Method POST `
                        -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$AgentName-webhook-bridge/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01" `
                        -DefaultProfile $AzContext
                    $WhCallback = $callback.value
                } catch { }

                Write-Host ''
                Write-Header '── Dynatrace setup (required to receive alerts) ──'
                Write-Host ''
                if ($WhCallback) {
                    Write-Host '  Webhook bridge URL (use this in Dynatrace):'
                    Write-Host "     $WhCallback"
                } else {
                    Write-Host "  ⚠ Webhook bridge not found. Check Azure portal → $ResourceGroup → $AgentName-webhook-bridge"
                }
                Write-Host ''
                Write-Host '  Option A: Dynatrace Workflow (recommended)'
                Write-Host '  ─────────────────────────────────────────────'
                Write-Host "  1. Go to Dynatrace → Automations → Workflows → + Workflow"
                Write-Host '  2. Add trigger: ''Davis problem'' trigger'
                Write-Host '     - Filter: event.status_transition == "CREATED"'
                Write-Host '       (fires once per problem, not on every status update)'
                Write-Host '  3. Add action: ''Send HTTP request'''
                Write-Host '     - Method: POST'
                if ($WhCallback) {
                    Write-Host "     - URL: $WhCallback"
                } else {
                    Write-Host '     - URL: <webhook bridge URL>'
                }
                Write-Host '     - Headers: Content-Type: application/json'
                Write-Host '     - Payload:'
                Write-Host '       {'
                Write-Host '         "ProblemID": "{{ event()[''event.id''] }}",'
                Write-Host '         "ProblemTitle": "{{ event()[''display_id''] }}: {{ event()[''event.name''] }}",'
                Write-Host '         "State": "{{ event()[''event.status''] }}",'
                Write-Host '         "ProblemSeverity": "{{ event()[''event.category''] }}",'
                Write-Host '         "ProblemURL": "{{ environment().url }}/ui/apps/dynatrace.classic.problems/#problems/problemdetails;pid={{ event()[''event.id''] }}",'
                Write-Host '         "ImpactedEntities": "{{ event()[''affected_entity_ids''] }}",'
                Write-Host '         "ProblemDetailsText": "{{ event()[''event.name''] }}"'
                Write-Host '       }'
                Write-Host '  4. Grant workflow permissions:'
                Write-Host '     Settings → Authorization → Automation Service → grant permissions'
                Write-Host '  5. Activate the workflow'
                Write-Host ''
                Write-Host '  Option B: Classic webhook (simpler but less control)'
                Write-Host '  ────────────────────────────────────────────────────'
                Write-Host '  1. Go to Settings → Integration → Problem notifications'
                Write-Host '  2. Add ''Custom Integration'' webhook'
                if ($WhCallback) {
                    Write-Host "  3. URL: $WhCallback"
                } else {
                    Write-Host '  3. URL: <webhook bridge URL>'
                }
                Write-Host '  4. Send test notification to verify'
                Write-Host ''
                Write-Host '  Test: trigger a problem in Dynatrace (or use the test button)'
                Write-Host '  Then check the agent portal for the incoming investigation:'
                Write-Host "  Portal: https://sre.azure.com/#/agent/$SubscriptionId/$ResourceGroup/$AgentName"
                Write-Host ''
            }
            'pagerduty-law-vmcosmos' {
                Write-Host ''
                Write-Header '── PagerDuty setup ──'
                Write-Host ''
                Write-Host "  1. Open the agent portal: https://sre.azure.com/#/agent/$SubscriptionId/$ResourceGroup/$AgentName"
                Write-Host '  2. Navigate to Incident Platforms → PagerDuty'
                Write-Host '  3. Complete the OAuth flow to connect your PagerDuty account'
                Write-Host '  4. Select which PagerDuty services to monitor'
                Write-Host '  5. The pd-p1p2 response plan routes P1/P2 incidents with customInstructions'
                Write-Host ''
            }
        }
    }
}

# ── Cleanup temp files ──
foreach ($f in $CleanupFiles) {
    if (Test-Path $f -ErrorAction SilentlyContinue) {
        Remove-Item $f -Recurse -Force -ErrorAction SilentlyContinue
    }
}
