# Getting Started — External (3P) Teams

Step-by-step guide to create, deploy, and manage an Azure SRE Agent.

## Prerequisites

- Azure subscription with permission to deploy resources and create role assignments
- PowerShell 7+, `Az.Accounts`, `Az.Resources`, and the Bicep CLI
- An existing authenticated Az PowerShell context for the deployment subscription
- At least one resource group to monitor

## Step 1: Open the repository

Use a checkout containing `sreagent-templates/bin/ps/Deploy-Agent.ps1`.
Start PowerShell 7+ at the repository root, then change to the templates directory:

```powershell
Set-Location sreagent-templates
```

## Step 2: Choose your path

Use the checked-in [FinOps Hubs agent configuration](../agents/finops-hubs/README.md)
for the current native PowerShell deployment path. It requires a real Hub
endpoint for Kusto access. The former generic/recipe generators and clone
helpers aren't present; don't pass unresolved recipe placeholders to deployment.
For an existing agent, first review the
[update limitations](../recipes/finops-hubs/README.md#deploy-to-an-existing-sre-agent).

## Step 3: Review the input configuration

```powershell
Get-Content agents/finops-hubs/agent.json
Get-Content agents/finops-hubs/connectors.json
```

The deployer reads these two JSON files directly. Command-line identity and
targeting parameters override `agent.json`; the remaining supported settings
come from JSON. It doesn't resolve secret files or assemble YAML, Markdown,
roles, or other data-plane assets. Never put secrets in committed JSON files.

### UAMI access (Managed Identity)

The Bicep template creates a User-Assigned Managed Identity (UAMI) and grants it Reader + Log Analytics Reader on your target RGs. Some connectors need additional UAMI access:

| What UAMI needs access to | How to grant | When |
|---|---|---|
| **Target resource groups** | Automatic — Bicep grants Reader + Log Analytics Reader (+ Contributor if accessLevel=High) | During deploy |
| **Target subscriptions** (if monitoring cross-sub) | `az role assignment create --assignee-object-id $UAMI --role Reader --scope /subscriptions/$TARGET_SUB` | After deploy |
| **Kusto/ADX cluster** | `az kusto database add-principal` with Viewer role | After deploy |
| **Teams / Outlook** | Separate connector setup and user consent; the current deployer doesn't process `roles.yaml` | After deploy |
| **ADO repos** (via MI) | Separate federated identity and repository setup; the current deployer doesn't process `ADO_USE_MI` | After deploy |

The deployer prints the ARM deployment object, not a dedicated UAMI principal
summary. To retrieve the principal later:

```bash
# Get UAMI principal ID from the agent's resource group
az identity list -g <agent-rg> --query "[0].principalId" -o tsv
```

### Adding RGs or subscriptions later

To grant the agent access to additional resource groups or subscriptions after initial deploy:

```bash
UAMI=$(az identity list -g <agent-rg> --query "[0].principalId" -o tsv)

# Add a new resource group
az role assignment create --assignee-object-id $UAMI --assignee-principal-type ServicePrincipal \
  --role Reader --scope /subscriptions/$SUB/resourceGroups/$NEW_RG

# Add Log Analytics Reader on the new RG
az role assignment create --assignee-object-id $UAMI --assignee-principal-type ServicePrincipal \
  --role "Log Analytics Reader" --scope /subscriptions/$SUB/resourceGroups/$NEW_RG

# Add Contributor if agent has accessLevel=High
az role assignment create --assignee-object-id $UAMI --assignee-principal-type ServicePrincipal \
  --role Contributor --scope /subscriptions/$SUB/resourceGroups/$NEW_RG
```

Then update `agent.json` → `identity.targetResourceGroups` to include the new RG and redeploy.

For connectors that use MI, no secrets are needed in files — just RBAC grants.

### Connector credentials

| Connector type | Auth | Where credentials go |
|---|---|---|
| AppInsights, Log Analytics, Azure Monitor | Managed Identity | No secrets — UAMI needs Reader on the resource (auto-granted for target RGs) |
| Kusto/ADX | Managed Identity | No secrets — UAMI needs Viewer on the cluster (grant after deploy) |
| MCP (Dynatrace, Datadog, Splunk, etc.) | Bearer token | `connectors.secrets.env` → `${ENV_VAR}` in `connectors.json` |
| GitHub | OAuth or PAT | Requires separate connector setup; the current deployer doesn't handle sign-in or resolve PAT environment variables |
| Azure DevOps | PAT / AAD / MI | Requires separate connector setup; the current deployer doesn't process these authentication environment variables |
| Teams / Outlook | OAuth consent | The current deployer doesn't process `roles.yaml`, create OAuth API connections, or print consent URLs |
| PagerDuty / ServiceNow | Portal setup | Configure via portal Incident Platforms page after deploy |

## Step 4: Check local inputs

There is no dry-run, what-if, or validate-only mode in the current script.
Use these non-deploying checks from `sreagent-templates/` in PowerShell:

```powershell
Get-Command New-AzSubscriptionDeployment, Get-AzContext, bicep -ErrorAction Stop
Get-Content agents/finops-hubs/agent.json -Raw | ConvertFrom-Json -ErrorAction Stop
Get-Content agents/finops-hubs/connectors.json -Raw | ConvertFrom-Json -ErrorAction Stop
Get-Command ./bin/ps/Deploy-Agent.ps1 -Syntax
```

These check local prerequisites, JSON syntax, and parameter discovery only.
They don't prove Azure permissions, connector health, Hub connectivity, or full
recipe readiness. Review identity, scope, and configuration before deploying.

## Step 5: Deploy

Run inside PowerShell 7+ from `sreagent-templates/`, replacing the placeholders:

```powershell
./bin/ps/Deploy-Agent.ps1 -InputPath agents/finops-hubs/ `
  -SubscriptionId '<subscription-id>' `
  -AgentName '<agent-name>' `
  -ResourceGroup '<agent-resource-group>' `
  -Location 'eastus2' `
  -TargetResourceGroups @('<target-resource-group-1>', '<target-resource-group-2>') `
  -KustoClusterUrl 'https://<cluster>.<region>.kusto.windows.net' `
  -KustoDatabase 'Hub'
```

`-TargetResourceGroups` takes a string array, not a comma-separated string.
Don't pass the array through `pwsh -File` from Bash. `-SubscriptionId` uses an
already available Az context without signing in or changing the saved context.
Without it, `agent.json.identity.subscription` is used when set, otherwise
deployment uses the current context.

The script reads the two JSON files, supplies supported parameters to
`bicep/main.bicep`, and calls `New-AzSubscriptionDeployment`. It checks that
`ProvisioningState` is `Succeeded`, prints the result, and returns the deployment
object. It doesn't run apply-extras, install recipe data-plane assets, write
deployment logs, or verify the live agent. ARM success isn't full recipe
installation. See the [exact parameter reference](../agents/finops-hubs/README.md#parameters).

## Step 6: Post-deploy setup

These are manual readiness checks, not steps performed by the deployer.
The full FinOps Hubs recipe remains incomplete until its missing data-plane
installation lifecycle is restored; don't assume its skills, plugins, Teams
connector, or scheduled tasks were installed.

1. **Open** https://sre.azure.com → find your agent
2. **Features** → enable:
   - `EnableWorkspaceTools` — file ops, terminal, project-aware tools
   - `EnableV2AgentLoop` — checkpoint-based resilience, hook support
3. **Model provider** → switch to Anthropic (preferred) or keep OpenAI
4. **Connectors** → verify all show healthy (green)
5. **GitHub/ADO repos** → sign in via OAuth if prompted
6. **MCP connectors** → verify bearer tokens are valid
7. **Test** → start a conversation, ask it to investigate something in your target RGs

## Common operations

The former export, clone, and backup helpers aren't present in this checkout.
The current deployment command doesn't replace them or export live state.

## Model providers

| Provider | Available | How to switch |
|---|---|---|
| Anthropic (claude-*) | ✅ preferred | Portal → Settings → Provider dropdown |
| OpenAI/MicrosoftFoundry (gpt-*) | ✅ | Portal → Settings → Provider dropdown |

3P agents can switch between Anthropic and OpenAI. Cannot select individual models — provider only.

## Supported regions

`eastus2` · `swedencentral` · `uksouth` · `australiaeast`
