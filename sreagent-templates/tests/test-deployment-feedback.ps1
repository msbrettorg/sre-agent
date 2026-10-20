param(
    [switch]$Child,
    [ValidateSet('Ok', 'Http', 'InvalidJson', 'EmptyJson', 'Token')]
    [string]$Scenario = 'Ok'
)

$verify = Join-Path $PSScriptRoot '../bin/ps/Verify-Agent.ps1'
if ($Child) {
    function Get-AzContext {
        param([switch]$ListAvailable)
        [pscustomobject]@{
            Subscription = [pscustomobject]@{ Id = 'test-subscription' }
            Tenant = [pscustomobject]@{ Id = 'test-tenant' }
        }
    }
    function Set-AzContext {
        param($Context, $Scope)
        $Context
    }
    function Disable-AzContextAutosave { param($Scope) }
    function Get-AzAccessToken { }
    function New-AzSubscriptionDeployment { }
    function Invoke-AzRestMethod {
        param($Method, $Uri, $DefaultProfile, $ResourceId, $ErrorAction)
        if ($Uri -like '*/DataConnectors?*') {
            return [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }
        if (-not $ResourceId) {
            return [pscustomobject]@{
                StatusCode = 200
                Content = '{"properties":{"agentEndpoint":"https://agent.test"}}'
            }
        }
        switch ($Scenario) {
            'Http' { return [pscustomobject]@{ StatusCode = 403; Content = '{"error":"denied"}' } }
            'InvalidJson' { return [pscustomobject]@{ StatusCode = 200; Content = '<html>error</html>' } }
            'EmptyJson' { return [pscustomobject]@{ StatusCode = 200; Content = '' } }
            'Token' { throw 'Az PowerShell token denied' }
        }
        $body = if ($Uri -match '/scheduledtasks|/incidentPlayground/filters|/extendedAgent/skills') {
            '[]'
        } elseif ($Uri -match '/Github/auth/status') {
            '{"isConfigured":false}'
        } else {
            '{"value":[]}'
        }
        return [pscustomobject]@{ StatusCode = 200; Content = $body }
    }
    & $verify -Subscription test-subscription -ResourceGroup test-rg -AgentName test-agent
    exit $LASTEXITCODE
}

$cases = @(
    @{ Name = 'Ok'; Exit = 0; Message = 'Results:' },
    @{ Name = 'Http'; Exit = 1; Message = 'HTTP 403' },
    @{ Name = 'InvalidJson'; Exit = 1; Message = 'Invalid JSON from data-plane endpoint' },
    @{ Name = 'EmptyJson'; Exit = 1; Message = 'Empty JSON from data-plane endpoint' },
    @{ Name = 'Token'; Exit = 1; Message = 'Az PowerShell token denied' }
)
foreach ($case in $cases) {
    $output = (& pwsh -NoProfile -File $PSCommandPath -Child -Scenario $case.Name 2>&1 | Out-String)
    if ($LASTEXITCODE -ne $case.Exit -or -not $output.Contains($case.Message)) {
        throw "$($case.Name) regression failed (exit $LASTEXITCODE): $output"
    }
}

$deploy = Get-Content (Join-Path $PSScriptRoot '../bin/ps/Deploy-Agent.ps1') -Raw
if ($deploy -notmatch '(?s)Current state verification.*?exit \$LASTEXITCODE' -or
    $deploy -notmatch '\$VerifyExit = \$LASTEXITCODE' -or
    $deploy -notmatch 'exit \$VerifyExit') {
    throw 'Deployment must propagate both skipped and post-deployment verification exit codes.'
}
Write-Host 'PowerShell deployment feedback regressions passed.'
