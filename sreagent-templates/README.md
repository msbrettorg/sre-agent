# Awesome Azure SRE Agent Recipes

Recipes and configuration assets for Azure SRE Agent. The current native
PowerShell deployer provisions ARM infrastructure and connectors, not the full
recipe's data-plane assets.

## Prerequisites

- PowerShell 7+
- `Az.Accounts` and `Az.Resources` PowerShell modules
- Bicep CLI on `PATH` for deployment of `bicep/main.bicep`
- An existing authenticated Az PowerShell context for the deployment subscription
- Permission to deploy resources and create the template's role assignments
- Existing workload resource groups in the deployment subscription

This path doesn't require Azure CLI, jq, Python, or PyYAML. The former
prerequisite installer and recipe-generation scripts aren't present.

## Quick Start

Use a checkout containing `sreagent-templates/bin/ps/Deploy-Agent.ps1`.
Run inside **PowerShell 7+**, starting at the repository root. Replace every
placeholder with your own values.

```powershell
Set-Location sreagent-templates

./bin/ps/Deploy-Agent.ps1 -InputPath agents/finops-hubs/ `
  -SubscriptionId '<subscription-id>' `
  -AgentName '<agent-name>' `
  -ResourceGroup '<agent-resource-group>' `
  -Location 'eastus2' `
  -TargetResourceGroups @('<target-resource-group-1>', '<target-resource-group-2>') `
  -KustoClusterUrl 'https://<cluster>.<region>.kusto.windows.net' `
  -KustoDatabase 'Hub'
```

This uses the checked-in FinOps Hubs config, not an unresolved recipe directory.
`-TargetResourceGroups` is a PowerShell string array, not one comma-separated
string. Invoke the script inside PowerShell rather than passing arrays through
`pwsh -File` from Bash.

`-SubscriptionId` uses an already available Az context without signing in or
changing the saved context. Without it, the script uses
`agent.json.identity.subscription` when set, otherwise the current context.
See the [FinOps Hubs quick start](agents/finops-hubs/README.md#quick-start)
and [parameter reference](agents/finops-hubs/README.md#parameters).

## Recipes

| Recipe | Platform | One-line |
|---|---|---|
| [finops-hubs](recipes/finops-hubs/) | FinOps Hubs | Hub-backed cost analytics and FinOps configuration assets; current deployment is ARM-only |
| [azmon-lawappinsights](recipes/azmon-lawappinsights/) | Azure Monitor | Alert response with AppInsights + Log Analytics, skills, subagents, scheduled tasks |
| [pagerduty-law-vmcosmos](recipes/pagerduty-law-vmcosmos/) | PagerDuty | VM + CosmosDB + HTTP error investigation with knowledge files and skills |
| [dynatrace-mcp](recipes/dynatrace-mcp/) | Dynatrace | Dynatrace MCP connector for investigating application errors |
| [minimal](recipes/minimal/) | (none) | Minimal agent — just infra + RBAC, add your own connectors and skills |

Each recipe README has the full parameter list, example values, and post-deploy steps.

> **Want a recipe for a different platform?** [Open a recipe request](https://github.com/microsoft/sre-agent/issues/new?template=recipe_request.md).

## CLI

| Command | Purpose |
|---|---|
| `./bin/ps/Deploy-Agent.ps1 -InputPath <config-directory>` | Deploy ARM infrastructure and connectors from `agent.json` and `connectors.json` |

The current script has no dry-run, what-if, force, export, clone, diff, or
verification mode. The former lifecycle helpers aren't in this checkout.

## What Gets Deployed

The native PowerShell path deploys these resources through `bicep/main.bicep`:

| Resource | Description |
|---|---|
| Resource Group | Container for all agent resources |
| User-Assigned Managed Identity (UAMI) | Agent's identity for RBAC |
| Log Analytics Workspace | Agent telemetry (created unless you supply one) |
| Application Insights | Agent monitoring (created unless you supply one) |
| SRE Agent | The agent itself |
| Connectors | Data sources (App Insights, LAW, PagerDuty, Dynatrace, etc.) |
| RBAC role assignments | Reader and Log Analytics Reader on target RGs; Contributor for High access; Monitoring Reader on the agent RG |

Skills, subagents, tools, common prompts, scheduled tasks, plugins, knowledge,
and tool policies aren't installed by the current script. It doesn't invoke
an assembler, `Apply-Extras.ps1`, or a verifier; those helpers aren't present.
ARM success isn't full recipe readiness or evidence that connector queries work.

## Deploy Backends

The supported entry point in this checkout is native PowerShell with Bicep:

| Backend | Command | Best for |
|---|---|---|
| **PowerShell + Bicep** | `./bin/ps/Deploy-Agent.ps1 -InputPath <config-directory>` | PowerShell 7+ with existing Az authentication |

The old Bash, Terraform, and azd wrapper instructions don't describe the current
deployment lifecycle.

## Clone an Agent

The former export and clone helpers aren't present. The current deployer doesn't
export live state or clone data-plane assets. See the
[existing-agent limitations](recipes/finops-hubs/README.md#deploy-to-an-existing-sre-agent)
before targeting an existing resource.

## Terraform

The former Terraform deployment wrapper isn't present. Use the PowerShell
quick start above; don't assume parity with the former wrapper.

## Azure Developer CLI (azd)

The current PowerShell deployer doesn't use azd environment variables or invoke
azd hooks. Use its explicit parameters and input JSON files instead.

## PowerShell

[`bin/ps/Deploy-Agent.ps1`](bin/ps/Deploy-Agent.ps1) is the current native
PowerShell entry point. It reads JSON directly and returns the ARM deployment
object after checking `ProvisioningState`. Follow the quick start above.

| Script | Purpose |
|---|---|
| `Deploy-Agent.ps1` | Deploy ARM infrastructure and connectors with Az PowerShell |

## CI/CD

See [examples/ci-cd/](examples/ci-cd/) for GitHub Actions and step-by-step setup.

## Contributing

A recipe is defined by 5 dimensions — think through each for your use case:

1. **Incident Platform** — AzMonitor, PagerDuty, ServiceNow
2. **Connectors** — Log Analytics, App Insights, Kusto, MCP (Dynatrace/Datadog/custom)
3. **Skills** — investigation playbooks for your workload (VM, CosmosDB, HTTP errors, etc.)
4. **Knowledge** — runbooks, architecture docs, incident templates
5. **Response Plan** — severity filter, autonomous vs review, customInstructions prompt

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full recipe design guide, naming conventions, and PR guidelines.
