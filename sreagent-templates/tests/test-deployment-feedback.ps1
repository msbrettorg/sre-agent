param(
    [switch]$Child,
    [ValidateSet('Ok', 'CachedTenants', 'Http', 'InvalidJson', 'EmptyJson', 'Token')]
    [string]$Scenario = 'Ok'
)

$verify = Join-Path $PSScriptRoot '../bin/ps/Verify-Agent.ps1'
if ($Child) {
    function Get-AzContext {
        [CmdletBinding()]
        param([switch]$ListAvailable)
        $selected = [pscustomobject]@{
            Subscription = [pscustomobject]@{ Id = 'test-subscription' }
            Tenant = [pscustomobject]@{ Id = 'test-tenant' }
        }
        if ($ListAvailable) {
            if ($Scenario -eq 'CachedTenants') {
                $selected
                [pscustomobject]@{
                    Subscription = [pscustomobject]@{ Id = 'test-subscription' }
                    Tenant = [pscustomobject]@{ Id = 'other-cached-tenant' }
                }
                return
            }
            throw 'Scripts must use the active context, not enumerate cached contexts.'
        }
        $selected
    }
    function Set-AzContext {
        param($Context, $Scope)
        throw 'Scripts must not change the caller context.'
    }
    function Disable-AzContextAutosave {
        param($Scope)
        throw 'Scripts must not change context autosave.'
    }
    function Get-AzAccessToken { }
    function New-AzSubscriptionDeployment { }
    function Invoke-AzRestMethod {
        param($Method, $Uri, $DefaultProfile, $ResourceId, $ErrorAction)
        if ($DefaultProfile.Subscription.Id -ne 'test-subscription' -or
            $DefaultProfile.Tenant.Id -ne 'test-tenant') {
            throw 'Requests must use the caller context unchanged.'
        }
        if (-not $ResourceId -and $Uri -notlike 'https://management.azure.com/subscriptions/test-subscription/*') {
            throw 'ARM requests must use the active context subscription.'
        }
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
    & $verify -ResourceGroup test-rg -AgentName test-agent
    exit $LASTEXITCODE
}

$cases = @(
    @{ Name = 'Ok'; Exit = 0; Message = 'Results:' },
    @{ Name = 'CachedTenants'; Exit = 0; Message = 'Results:' },
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

$scripts = @(
    '../bicep/Assemble-Agent.ps1',
    '../bicep/Apply-Extras.ps1',
    '../bin/ps/Deploy-Agent.ps1',
    '../bin/ps/Diff-Agent.ps1',
    '../bin/ps/Verify-Agent.ps1',
    '../bin/ps/Export-Agent.ps1',
    '../bin/ps/Clone-Agent.ps1',
    '../bin/ps/Deploy-Tf.ps1',
    '../bin/ps/Az-PowerShell.ps1'
)
foreach ($script in $scripts) {
    $path = Join-Path $PSScriptRoot $script
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "${script}: $($parseErrors | Out-String)" }
    if ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -match '^(From)?Subscription(Id)?$') {
        throw "${script}: subscription IDs must come from the active context, not script parameters."
    }
    $forbidden = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        ($node.GetCommandName() -in @(
            'Get-RequiredAzContext', 'Set-AzContext', 'Select-AzSubscription',
            'Disable-AzContextAutosave', 'Enable-AzContextAutosave',
            'Connect-AzAccount', 'Clear-AzContext', 'Remove-AzContext',
            'Import-AzContext', 'Save-AzContext'
        ) -or ($node.GetCommandName() -eq 'Get-AzContext' -and
            $node.CommandElements.Extent.Text -contains '-ListAvailable'))
    }, $true)
    if ($forbidden.Count) { throw "${script}: scripts must not manage or enumerate caller contexts." }
}

$deploy = Get-Content (Join-Path $PSScriptRoot '../bin/ps/Deploy-Agent.ps1') -Raw
if ($deploy -match 'identity\.subscription|RequestedSubscriptionId') {
    throw 'Deployment must use the active context, not subscription metadata from agent.json.'
}
if ($deploy -notmatch '(?s)Current state verification.*?exit \$LASTEXITCODE' -or
    $deploy -notmatch '\$VerifyExit = \$LASTEXITCODE' -or
    $deploy -notmatch 'exit \$VerifyExit') {
    throw 'Deployment must propagate both skipped and post-deployment verification exit codes.'
}
Write-Host 'PowerShell deployment feedback regressions passed.'
