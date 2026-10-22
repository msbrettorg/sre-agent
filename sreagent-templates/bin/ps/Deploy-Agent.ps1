[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroup,

    [Parameter()]
    [string]$AgentName,

    [Parameter()]
    [string]$Location,

    [Parameter()]
    [string[]]$TargetResourceGroups,

    [Parameter()]
    [string]$KustoClusterUrl,

    [Parameter()]
    [string]$KustoDatabase = 'Hub',

    [Parameter(Position = 1)]
    [string]$DeploymentName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BinDir    = Split-Path -Parent $ScriptDir
$RootDir   = Split-Path -Parent $BinDir
$Template  = Join-Path $RootDir 'bicep/main.bicep'

if (-not $InputPath) {
    $InputPath = Join-Path $RootDir 'agents/finops-hubs'
}

$resolved  = Resolve-Path $InputPath -ErrorAction Stop
$ConfigDir = $resolved.Path

$AgentJsonPath      = Join-Path $ConfigDir 'agent.json'
$ConnectorsJsonPath = Join-Path $ConfigDir 'connectors.json'

if (-not (Test-Path $AgentJsonPath)) {
    throw "agent.json not found at $AgentJsonPath"
}
if (-not (Test-Path $ConnectorsJsonPath)) {
    throw "connectors.json not found at $ConnectorsJsonPath"
}
if (-not (Test-Path $Template)) {
    throw "main.bicep not found at $Template"
}

$agentCfg      = Get-Content -Path $AgentJsonPath -Raw | ConvertFrom-Json -AsHashtable
$connectorsCfg = Get-Content -Path $ConnectorsJsonPath -Raw | ConvertFrom-Json -AsHashtable

if (-not $DeploymentName) {
    $DeploymentName = "sre-agent-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

$identity = if ($agentCfg.ContainsKey('identity') -and $null -ne $agentCfg['identity']) { $agentCfg['identity'] } else { @{} }
$access   = if ($agentCfg.ContainsKey('access') -and $null -ne $agentCfg['access']) { $agentCfg['access'] } else { @{} }
$toggles  = if ($agentCfg.ContainsKey('toggles') -and $null -ne $agentCfg['toggles']) { $agentCfg['toggles'] } else { @{} }
$cToggles = if ($connectorsCfg.ContainsKey('toggles') -and $null -ne $connectorsCfg['toggles']) { $connectorsCfg['toggles'] } else { @{} }

$EffectiveSubscriptionId = if ($SubscriptionId) {
    $SubscriptionId
} elseif ($identity.ContainsKey('subscription') -and $identity['subscription']) {
    [string]$identity['subscription']
} else {
    ''
}

$EffectiveAgentName = if ($AgentName) {
    $AgentName
} elseif ($identity.ContainsKey('agentName') -and $identity['agentName']) {
    [string]$identity['agentName']
} else {
    'finops-hubs-sre'
}

$EffectiveResourceGroup = if ($ResourceGroup) {
    $ResourceGroup
} elseif ($identity.ContainsKey('resourceGroup') -and $identity['resourceGroup']) {
    [string]$identity['resourceGroup']
} else {
    $EffectiveAgentName
}

$EffectiveLocation = if ($Location) {
    $Location
} elseif ($identity.ContainsKey('location') -and $identity['location']) {
    [string]$identity['location']
} else {
    'eastus2'
}

[string[]]$EffectiveTargetRGs = if ($PSBoundParameters.ContainsKey('TargetResourceGroups')) {
    @($TargetResourceGroups)
} elseif ($identity.ContainsKey('targetResourceGroups') -and $null -ne $identity['targetResourceGroups']) {
    @($identity['targetResourceGroups'] | Where-Object { $_ -and $_ -notmatch '^\{\{.*\}\}$' })
} else {
    @()
}

$EffectiveKustoUrl = if ($KustoClusterUrl) {
    $KustoClusterUrl
} elseif ($env:KUSTO_CLUSTER_URI) {
    $env:KUSTO_CLUSTER_URI
} else {
    ''
}

function Format-KustoDataSource([string]$RawUrl, [string]$DbName, [bool]$DbExplicit) {
    $trimmed = $RawUrl.TrimEnd('/')
    $uri = [System.Uri]$trimmed
    $origin = "$($uri.Scheme)://$($uri.Authority)"
    $pathPart = $uri.AbsolutePath.Trim('/')
    if ($DbExplicit -or -not $pathPart) {
        return "$origin/$DbName"
    }
    return "$origin/$pathPart"
}

[object[]]$rawConnectors = if ($connectorsCfg.ContainsKey('connectors') -and $null -ne $connectorsCfg['connectors']) {
    @($connectorsCfg['connectors'])
} else {
    @()
}

[object[]]$resolvedConnectors = @()
foreach ($c in $rawConnectors) {
    $props = $c['properties']
    if ($c['name'] -eq 'finops-hub-kusto' -or ($props -and $props['dataConnectorType'] -eq 'Kusto')) {
        if ($EffectiveKustoUrl) {
            $props['dataSource'] = Format-KustoDataSource -RawUrl $EffectiveKustoUrl -DbName $KustoDatabase -DbExplicit $PSBoundParameters.ContainsKey('KustoDatabase')
        } elseif ($props['dataSource'] -match '^\{\{.*\}\}$' -or [string]::IsNullOrWhiteSpace([string]$props['dataSource'])) {
            Write-Warning "Skipping connector '$($c['name'])' because Kusto dataSource is a placeholder and -KustoClusterUrl was not specified."
            continue
        }
    }
    $resolvedConnectors += $c
}

$bicepParams = @{
    agentName                   = $EffectiveAgentName
    agentResourceGroupName      = $EffectiveResourceGroup
    location                    = $EffectiveLocation
    targetResourceGroups        = [string[]]@($EffectiveTargetRGs)
    accessLevel                 = if ($access['accessLevel']) { [string]$access['accessLevel'] } else { 'Low' }
    actionMode                  = if ($access['actionMode']) { [string]$access['actionMode'] } else { 'Review' }
    upgradeChannel              = if ($agentCfg['upgradeChannel']) { [string]$agentCfg['upgradeChannel'] } else { 'Preview' }
    defaultModelProvider        = if ($agentCfg['defaultModelProvider'] -and $agentCfg['defaultModelProvider'] -notmatch '^\{\{.*\}\}$') { [string]$agentCfg['defaultModelProvider'] } else { 'MicrosoftFoundry' }
    monthlyAgentUnitLimit       = if ($null -ne $agentCfg['monthlyAgentUnitLimit']) { [int]$agentCfg['monthlyAgentUnitLimit'] } else { 10000 }
    tags                        = if ($agentCfg['tags']) { $agentCfg['tags'] } else { @{} }
    existingManagedIdentityId   = if ($agentCfg['existingUamiId'] -and $agentCfg['existingUamiId'] -notmatch '^\{\{.*\}\}$') { [string]$agentCfg['existingUamiId'] } else { '' }
    existingAgentAppInsightsId  = if ($agentCfg['existingAgentAppInsightsId'] -and $agentCfg['existingAgentAppInsightsId'] -notmatch '^\{\{.*\}\}$') { [string]$agentCfg['existingAgentAppInsightsId'] } else { '' }
    enableWebhookBridge         = if ($null -ne $toggles['enableWebhookBridge']) { [bool]$toggles['enableWebhookBridge'] } else { $false }
    webhookBridgeTriggerUrl     = if ($toggles['webhookBridgeTriggerUrl']) { [string]$toggles['webhookBridgeTriggerUrl'] } else { '' }
    enableAppInsightsConnector  = if ($null -ne $cToggles['enableAppInsightsConnector']) { [bool]$cToggles['enableAppInsightsConnector'] } else { $false }
    appInsightsResourceId       = if ($cToggles['appInsightsResourceId']) { [string]$cToggles['appInsightsResourceId'] } else { '' }
    appInsightsAppId            = if ($cToggles['appInsightsAppId']) { [string]$cToggles['appInsightsAppId'] } else { '' }
    enableLogAnalyticsConnector = if ($null -ne $cToggles['enableLogAnalyticsConnector']) { [bool]$cToggles['enableLogAnalyticsConnector'] } else { $false }
    lawResourceId               = if ($cToggles['lawResourceId']) { [string]$cToggles['lawResourceId'] } else { '' }
    enableAzureMonitorConnector = if ($null -ne $cToggles['enableAzureMonitorConnector']) { [bool]$cToggles['enableAzureMonitorConnector'] } else { $false }
    azureMonitorLookbackDays    = if ($null -ne $cToggles['azureMonitorLookbackDays']) { [int]$cToggles['azureMonitorLookbackDays'] } else { 7 }
    connectors                  = $resolvedConnectors
}

$deploySplat = @{
    Name                    = $DeploymentName
    Location                = $EffectiveLocation
    TemplateFile            = $Template
    TemplateParameterObject = $bicepParams
    ErrorAction             = 'Stop'
}

if ($EffectiveSubscriptionId) {
    $currentCtx = Get-AzContext -ErrorAction Stop
    if ($currentCtx -and $currentCtx.Subscription -and $currentCtx.Subscription.Id -ne $EffectiveSubscriptionId) {
        $matchingCtx = Get-AzContext -ListAvailable | Where-Object { $_.Subscription -and $_.Subscription.Id -eq $EffectiveSubscriptionId } | Select-Object -First 1
        if (-not $matchingCtx) {
            throw "No available Az context found for subscription '$EffectiveSubscriptionId'."
        }
        $deploySplat['DefaultProfile'] = $matchingCtx
    }
}

Write-Host "Deploying SRE Agent '$EffectiveAgentName' to resource group '$EffectiveResourceGroup' ($EffectiveLocation)..." -ForegroundColor Cyan

$deployResult = New-AzSubscriptionDeployment @deploySplat

Write-Host ($deployResult | Format-List | Out-String)

if ($deployResult.ProvisioningState -ne 'Succeeded') {
    throw "Deployment finished with state: $($deployResult.ProvisioningState)"
}

Write-Host "Deployment Succeeded: $($deployResult.ProvisioningState)" -ForegroundColor Green
return $deployResult
