# Shared Az PowerShell authentication and REST helpers.

function Get-RequiredAzContext {
    param([Parameter(Mandatory)][string]$SubscriptionId)

    $contexts = @(
        Get-AzContext -ListAvailable |
            Where-Object { $_.Subscription.Id -eq $SubscriptionId }
    )
    if ($contexts.Count -eq 0) {
        throw "No Az PowerShell context found for subscription $SubscriptionId. Run Connect-AzAccount first."
    }

    $tenantIds = @($contexts | ForEach-Object { $_.Tenant.Id } | Sort-Object -Unique)
    if ($tenantIds.Count -ne 1) {
        throw "Multiple Az PowerShell tenants contain subscription $SubscriptionId. Remove stale contexts or select one explicitly."
    }

    Disable-AzContextAutosave -Scope Process | Out-Null
    return Set-AzContext -Context $contexts[0] -Scope Process -ErrorAction Stop
}

function ConvertFrom-AzRestContent {
    param([Parameter(Mandatory)][object]$Response)

    if ($Response.StatusCode -lt 200 -or $Response.StatusCode -ge 300) {
        throw "Azure REST request failed with HTTP $($Response.StatusCode): $($Response.Content)"
    }
    if ([string]::IsNullOrWhiteSpace($Response.Content)) {
        return $null
    }
    return $Response.Content | ConvertFrom-Json
}

function Invoke-AzJsonRest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][object]$DefaultProfile,
        [object]$Payload,
        [string]$ResourceId
    )

    $parameters = @{
        Method         = $Method
        Uri            = $Uri
        DefaultProfile = $DefaultProfile
        ErrorAction    = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Payload')) {
        $parameters.Payload = if ($Payload -is [string]) {
            $Payload
        } else {
            $Payload | ConvertTo-Json -Compress -Depth 100
        }
    }
    if ($ResourceId) {
        $parameters.ResourceId = $ResourceId
    }

    $response = Invoke-AzRestMethod @parameters
    return ConvertFrom-AzRestContent -Response $response
}

function Invoke-AzRestContent {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][object]$DefaultProfile,
        [object]$Payload,
        [string]$ResourceId
    )

    $parameters = @{
        Method         = $Method
        Uri            = $Uri
        DefaultProfile = $DefaultProfile
        ErrorAction    = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Payload')) {
        $parameters.Payload = if ($Payload -is [string]) {
            $Payload
        } else {
            $Payload | ConvertTo-Json -Compress -Depth 100
        }
    }
    if ($ResourceId) {
        $parameters.ResourceId = $ResourceId
    }

    $response = Invoke-AzRestMethod @parameters
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Azure REST request failed with HTTP $($response.StatusCode): $($response.Content)"
    }
    return [string]$response.Content
}

function Get-AzBearerToken {
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter(Mandatory)][object]$DefaultProfile
    )

    $result = Get-AzAccessToken -ResourceUrl $ResourceUrl -DefaultProfile $DefaultProfile -ErrorAction Stop
    if ($result.Token -is [securestring]) {
        return [System.Net.NetworkCredential]::new('', $result.Token).Password
    }
    return [string]$result.Token
}
