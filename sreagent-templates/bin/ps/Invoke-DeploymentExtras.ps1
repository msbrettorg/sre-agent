param(
    [switch]$Preflight,
    [string]$Subscription,
    [string]$ResourceGroup,
    [string]$AgentName,
    [string]$ExtrasFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$apply = Join-Path $PSScriptRoot '../../bicep/Apply-Extras.ps1'
if (-not (Test-Path -LiteralPath $apply -PathType Leaf)) {
    throw "Required deployment lifecycle script not found: $apply"
}

$prerequisites = Join-Path $PSScriptRoot 'Check-Prerequisites.ps1'
if (-not (Test-Path -LiteralPath $prerequisites -PathType Leaf)) {
    throw "Required deployment prerequisites script not found: $prerequisites"
}
. $prerequisites
if (-not (Test-Prerequisites -IncludeTar)) {
    throw 'PowerShell extras prerequisites are missing; no deployment was started.'
}
if (-not $Subscription) {
    throw 'The caller subscription is required to validate deployment authentication.'
}
$authentication = Join-Path $PSScriptRoot 'Az-PowerShell.ps1'
if (-not (Test-Path -LiteralPath $authentication -PathType Leaf)) {
    throw "Required deployment authentication helper not found: $authentication"
}
. $authentication
$null = Get-RequiredAzContext -SubscriptionId $Subscription -ValidateOnly
if ($Preflight) { return }

if (-not $Subscription -or -not $ResourceGroup -or -not $AgentName -or
    -not $ExtrasFile -or -not (Test-Path -LiteralPath $ExtrasFile -PathType Leaf)) {
    throw 'Subscription, resource group, agent name, and an existing extras file are required.'
}

$applyParams = @{
    Subscription    = $Subscription
    ResourceGroup   = $ResourceGroup
    AgentName       = $AgentName
    ExtrasFile      = $ExtrasFile
    RequireComplete = $true
}
if ($Force) { $applyParams.Force = $true }
& $apply @applyParams
