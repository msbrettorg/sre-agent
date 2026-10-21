# FinOps Hubs

Deploy an Azure SRE Agent for FinOps Hubs cost analytics and FinOps operations.

## Prerequisites

- A deployed FinOps Hub with an Azure Data Explorer endpoint
- At least one Azure resource group to monitor
- PowerShell 7+, the `Az.Accounts` and `Az.Resources` modules, and the Bicep CLI
- An existing authenticated Az PowerShell context for the deployment subscription,
  with permission to deploy resources and create role assignments
- A Microsoft Teams account for post-deployment connector authorization
- SRE Agent Author or Administrator access to install public marketplace plugins
- Reader access for the agent identity on every subscription assessed for quota,
  capacity, or cross-subscription availability-zone mapping

The complete recipe requires a Hub. For customers without one, including those
using third-party cost tools, see [Deploy without a FinOps Hub](#deploy-without-a-finops-hub).
For a private Hub, complete [Private networking](#private-networking) before deployment.
Run the following commands from `sreagent-templates/`.

## Quick Start

Use the checked-in agent configuration. The former `New-Agent.ps1` generator
isn't present in this checkout. Run this example inside PowerShell 7+ from
`sreagent-templates/`, replacing the placeholders:

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

`-TargetResourceGroups` is a string array, not a comma-separated string.
Run inside PowerShell rather than passing an array through `pwsh -File` from
Bash. `-SubscriptionId` uses an already available Az context without signing in
or switching the saved context. If omitted, `identity.subscription` is used when
set, otherwise deployment uses the current context.

**The current command deploys ARM infrastructure and connectors only.** It reads
`agent.json` and `connectors.json`, then calls `New-AzSubscriptionDeployment`
with `bicep/main.bicep`. It doesn't assemble YAML or apply data-plane assets.
The Bash deployer, generator, `Apply-Extras.ps1`, and verifier aren't present
in this checkout. The recipe's skills, subagents, tools, scheduled tasks,
plugins, knowledge, Teams connector, and tool policies aren't installed by this
command. See the [agent parameter reference](../../agents/finops-hubs/README.md#parameters)
for the exact supported parameters and defaults.

## Expected deployment output

The following is illustrative, not a newly recorded deployment:

```text
Deploying SRE Agent '<agent-name>' to resource group '<agent-resource-group>' (eastus2)...
...
ProvisioningState : Succeeded
...
Deployment Succeeded: Succeeded
```

Interpret each stage separately:

| Output | Meaning |
|---|---|
| `Deployment Succeeded: Succeeded` | The subscription-scoped ARM deployment succeeded. No extras or verification stages follow. |
| Connector `Succeeded` | ARM reports the connector provisioned. This doesn't prove a query works, the caller can obtain a data-plane token, or Teams is authorized. |
| Warning about a skipped Kusto connector | Its data source is unresolved. Supply the real `-KustoClusterUrl`; ARM success without that connector isn't Hub readiness. |
| Deployment error or a non-`Succeeded` state | The script stops with an error. Review it before retrying; previously created resources aren't rolled back by the script. |

The script prints the deployment result and returns it as a PowerShell object.
It doesn't write a deployment log file or run `expected-config.json` checks.
Inspect the agent and connector health in the portal, and test Hub queries
separately before claiming end-to-end readiness.

### Cloud Shell data-plane token failure

The current deployer doesn't request an SRE data-plane token or apply extras.
Instructions for recovering the former extras/verifier flow don't apply to this
checkout. It has no `-Force`, `-DryRun`, or extras-only option. Don't attempt to
repair missing recipe assets by rerunning an unsupported flag or changing the
authenticated context. The missing apply-extras lifecycle is a repository-local
blocker for full recipe installation.

## Deploy to an existing SRE Agent

There is no `existingAgentId` or extras-only flag. `Deploy-Agent.ps1` targets
the agent at the specified subscription, resource group, and name. It reconciles
ARM infrastructure and connectors; this isn't an additive-only import.
An existing UAMI or Application Insights ID refers to a supporting resource,
not to the agent.

Review the existing agent and its source configuration before deploying.
The former export, diff, and merge helpers aren't available. Supply the existing
identity explicitly only after confirming the intended ARM state:

```powershell
./bin/ps/Deploy-Agent.ps1 -InputPath agents/finops-hubs/ `
  -SubscriptionId '<existing-subscription-id>' `
  -ResourceGroup '<existing-agent-resource-group>' `
  -AgentName '<existing-agent-name>' `
  -Location '<existing-agent-region>' `
  -TargetResourceGroups @('<existing-monitored-resource-group>') `
  -KustoClusterUrl 'https://<cluster>.<region>.kusto.windows.net/Hub'
```

Preserve the existing managed identity, telemetry, access mode, model,
tags, and monitoring scope when reviewing `agent.json`.
`-TargetResourceGroups` is the complete desired scope,
not just additional groups. Review connector name collisions: a same-name ARM
connector can be updated. The script doesn't update tools, skills, or tasks.

**Stop if the intended existing state can't be represented by the canonical
configuration.** For example, this Bicep model builds monitoring scope from
resource-group names; it can't round-trip arbitrary subscription-level managed
resources. Neither
ARM success nor static parameter checks prove the update preserves all
existing state. The current script doesn't forward `networkConfiguration`,
`defaultModelName`, or `skipRoleAssignments` to Bicep. Stop if preserving the
existing state requires settings the script doesn't support.

## Private networking

**A private-only Hub isn't supported by the recipe's Kusto connector path.**
The current [SRE Agent network-integration documentation](https://learn.microsoft.com/azure/sre-agent/network-integration#traffic-routing-summary)
states that connector traffic uses the public internet and isn't routed through
the VNet (checked October 20, 2026). The recipe provisions `finops-hub-kusto`
as a Kusto connector; VNet settings alone don't make it reach a cluster with
public access disabled. This repository doesn't define an alternate private-only
connector path. If that is a requirement, stop before deploying the complete
recipe. Don't enable public access or introduce another integration to work
around it without a separately approved design.

The Bicep template defines agent VNet integration parameters, but the current
`Deploy-Agent.ps1` doesn't forward `agent.json.networkConfiguration` or expose
network parameters. **Stop if VNet integration is required.** The configuration
reference below isn't an executable deployment path with the current script.

The template doesn't provision a FinOps Hub private endpoint, private DNS zones, peering,
routes, or firewall rules for this recipe. Have the network owner establish
the private connectivity and DNS path for VNet-routed sandbox/tool traffic first.
This doesn't remove the connector limitation. See the linked
[FinOps Hubs private-networking guide](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/private-networking)
for the Hub side and the repository's
[VNet-integrated example](../../examples/vnet-integrated-keyvault/README.md)
for how agent subnet integration and private DNS fit together; that example
targets Key Vault and doesn't establish private Hub connector support.

The historical config shape is shown below for reference only; the current
deployer doesn't read it:

```json
"networkConfiguration": {
  "type": "vnet",
  "subnetId": "/subscriptions/<sub>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<agent-subnet>",
  "usePrivateDnsResolution": true,
  "allowedHosts": [],
  "allowHttpMcpServerNetworkAccess": true
}
```

This is a property fragment, not a replacement for the rest of `agent.json`.
The dedicated subnet must be **/27 or larger**, in the agent's region, delegated
to `Microsoft.App/environments`, and connected to the intended private endpoints
with working DNS and routing. Use the normal cluster FQDN in
`finopsHubClusterUri`; private DNS must resolve it through the intended private
path. Keep `/Hub` in the connector URI.

The current deployer doesn't map these fields to Bicep, create a subnet, or
configure its delegation. Editing this fragment alone doesn't enable private
networking.

Allow outbound dependencies required by the selected assets, including ARM MCP,
Teams, plugin sources, knowledge URLs, and the stdio MCP server's package source.
The supported `allowedHosts`, `allowedRegistries`, and
`allowedCodeRepositories` fields select managed-infrastructure bypass paths,
not private routes. Don't put a private Hub hostname in `allowedHosts` to try
to establish private access. `allowHttpMcpServerNetworkAccess: true` also enables
a managed path for remote MCP traffic; review that choice against your egress
policy. Network access doesn't grant Kusto database access to the
system-assigned identity.

Use `bin/ps/Deploy-Agent.ps1` only after resolving the connector-access requirement in an
approved design. Validate private name resolution and the intended tool request
from the agent's execution environment, and test connector queries separately.
Public Cloud Shell connectivity doesn't prove either path works. Neither
connector `Succeeded` nor ARM deployment success proves end-to-end private query
access. VNet integration is egress-only, not a private inbound agent endpoint.

## Deploy without a FinOps Hub

**The complete `finops-hubs` recipe isn't a supported no-Hub deployment.**
Its historical generation inputs require `finopsHubClusterUri`, its verification spec requires
`finops-hub-kusto`, and its tools and tasks expect Hub functions such as
`Costs()`, `Prices()`, `Recommendations()`, and `Transactions()`. An empty or
dummy URI doesn't turn it into a no-Hub variant.

The existing minimal recipe describes an agent without Hub assets, but its
former generator isn't available in this checkout. Don't pass its unresolved
recipe placeholders directly to the deployer or use a dummy Hub URL.
There is no verified generated-config quick start here for a no-Hub agent.
The current ARM-only command doesn't install FinOps Hubs skills, tools,
reports, or 19 scheduled tasks. It doesn't read a third-party FinOps product.
This repository defines no no-Hub FinOps recipe, switch, or third-party
cost-data adapter for this solution; adding one requires a separately scoped
implementation. Azure Cost Management and capacity APIs can supply some evidence
without a Hub, but they aren't drop-in replacements for the Hub data model or
FOCUS-based KPI and historical reports.

The following matrix describes the **current FinOps Hubs task definitions** if
considering a future customization. It isn't a claim that these tasks are
installed by `minimal`, or that removing a connector safely customizes them.

| Scheduled task names | Without a Hub |
|---|---|
| `HubsHealthCheck`, `Monthly`, `Semiannual`, `AIWorkloadCostAnalysis` | Core output unavailable: Hub health/freshness, monthly and fiscal KPI reporting, or AI cost/token analytics require Hub data. `Semiannual` is defined in `yoy-report.yaml`. |
| `CapacityDailyMonitor`, `MonitoringScopeValidation` | Azure quota/inventory checks can collect evidence, but required Hub freshness and monitoring-coverage checks can't complete. |
| `CapacityMonthlyPlanning`, `CapacityQuarterlyStrategy` | Incomplete: Hub cost forecasting, commitment utilization/waste, savings, MACC, and unit-economics evidence are required for the full planning/strategy output. |
| `BenefitRecommendationReview`, `AlertCoverageAudit` | Native recommendations or alert inventory can be collected; required Hub recommendation reconciliation and anomaly KPI evidence remain unavailable. |
| `CapacityWeeklySupplyReview`, `CostOptimization` | Hub evidence is conditional in the prompts. Native quota, CRG, SKU, recommendation, and inventory work can remain useful; Hub trends, commitment KPI, and unit-cost sections are unavailable. This doesn't make the full recipe deployable without a Hub. |
| `StoragePaasGrowthForecast` | Native resource/quota growth analysis is possible. The tool list makes Hub KPI enrichment conditional, but the later forecast step requests it without a guard. Don't claim the full task is supported without adapting that requirement. |
| `AdvisorSuppressionReview`, `BudgetCoverageAudit`, `ComputeUtilizationTrend`, `DbQuotaAudit`, `NonComputeQuotaAudit`, `SkuAvailabilityAudit` | Core evidence uses Resource Graph or native Azure quota/SKU APIs rather than Hub data. Access to the assessed scopes, prior observations for trends, specialist tooling, and configured delivery still apply. |

Without Hub data, FinOps Kusto KPI queries, Hub ingestion/export troubleshooting,
Hub allocation/tagging analytics, historical transaction/savings analysis, and
Hub-backed reports can't produce their specified results. Missing data or access
must remain explicit; don't substitute third-party financial data or report
incomplete tasks as successful. This guide doesn't change task prompts,
connectors, permissions, or agent capabilities.

## Post-deployment setup

The following describes the full recipe's requirements. The current ARM-only
deployer doesn't install the data-plane assets or Teams connector.

Complete the interactive OAuth authorization for Microsoft Teams after every
new deployment.

### Authorize Microsoft Teams

1. Open [Azure SRE Agent](https://sre.azure.com).
2. Select the deployed agent, then go to **Builder** > **Connectors**.
3. Open **Microsoft Teams** and complete the interactive OAuth sign-in.

Teams authorization is intentionally left to the user. The recipe does not
collect, store, or automate user credentials.

### Authorize Azure Resource Manager MCP

Grant the agent's system-assigned managed identity access to the required Cost
Management and billing scopes. The **azure-resource-manager-mcp** connector uses
the ARM MCP endpoint as its data source and requests an `AzureARM` token for
`https://mcp.management.azure.com/.default`. It does not require interactive user
authentication or stored credentials.

### Set up the FinOps Hub Live Reports

See the [Live Reports README](live-reports/README.md) for preparation, manual
upload, and local live-data preview instructions for both
`FinOps-Hub-MTD-KPI-Cockpit.html` and `FinOps-Hub-Savings-Plans.html`.

## Parameters

These are the recipe's historical generation inputs, **not** parameters accepted
by the current deployer. The generator isn't present. For executable deployment
arguments, use the [agent parameter reference](../../agents/finops-hubs/README.md#parameters).

| Parameter | Required | Description |
|---|---|---|
| `agentName` | Yes | Lowercase Azure SRE Agent name |
| `resourceGroup` | Yes | Resource group for the agent |
| `location` | Yes | Supported Azure SRE Agent region |
| `targetRGs` | Yes | Comma-separated resource groups to monitor |
| `finopsHubClusterUri` | Yes | FinOps Hub Kusto cluster URI, including the `Hub` database |
| `existingUamiId` | No | Existing user-assigned managed identity resource ID |
| `modelProvider` | No | `Anthropic` or `Azure OpenAI` |
| `existingAgentAppInsightsId` | No | Existing Application Insights resource ID for agent telemetry |

## What You Get

These are the full recipe assets, not a claim that the current ARM-only command
installs all of them.

| Category | Items |
|---|---|
| **Agent** | Review-mode FinOps Hubs SRE Agent |
| **Connectors** | FinOps Hub Kusto, Microsoft Teams, Azure Resource Manager HTTP MCP, and the FinOps Toolkit read-only Kusto stdio MCP server; Teams requires interactive authorization and both Azure MCP connectors use the agent system-assigned managed identity |
| **Tools** | 51 FinOps Kusto and Python tools, including read-only cross-subscription zone mapping, plus 14 explicitly selected Cost Management and Pricing MCP tools; all five built-in Visualization tools and all five built-in Log Query tools are enabled and globally allowed |
| **Skills** | Azure capacity management from its public marketplace, FinOps Toolkit from its official plugin URL, plus the official standalone Azure Cost Management skill |
| **Subagents** | FinOps, finance, capacity, database, and hub specialists |
| **Automations** | Scheduled FinOps and capacity operations |
| **Knowledge** | Eight FinOps Hubs guides plus seven public Azure capacity, quota, reservation, zone-mapping, AKS upgrade, and resilience references |

The Azure Resource Manager MCP connector is generated from the recipe with the
`x-mcp-toolset: CostManagement` custom header, `AzureARM` authentication, the
`https://mcp.management.azure.com/.default` token scope, and the agent's
system-assigned managed identity. `create_budget` remains governed by the
agent's **Review** action mode and is not included in the global auto-allow policy.
The recipe separately enables and globally allows every built-in Visualization tool
(`PlotAreaChartWithCorrelation`, `PlotBarChart`, `PlotHeatmap`, `PlotPieChart`,
and `PlotScatter`) and Log Query tool (`KustoClient`,
`QueryAppInsightsByAppId`, `QueryAppInsightsByResourceId`,
`QueryLogAnalyticsByResourceId`, and `QueryLogAnalyticsByWorkspaceId`).
`tool-overrides.json` controls the portal's On/Off state; `tool-permissions.json`
controls the separate Allow/Ask/Deny approval policy.
The `azure-mcp-server` stdio connector matches the FinOps Toolkit plugin's
declared `@azure/mcp` Kusto read-only server requirement; it does not use
ConnectorV2.

## Plugin skills

The recipe registers the public
[`microsoft/azcapman`](https://github.com/microsoft/azcapman) and
[`microsoft/finops-toolkit`](https://github.com/microsoft/finops-toolkit)
marketplaces. It installs `azure-capacity-management` from its marketplace and
installs `finops-toolkit` directly from `src/templates/agent-plugin` because the
SRE Agent marketplace resolver doesn't discover skills through that repository's
plugin symlink. The direct installation declares `sourceRef: dev`; because the
documented install API doesn't accept a branch field, deployment fails closed
unless `dev` is the repository's default branch and verifies the installed commit
against `dev` HEAD. A stale installation is replaced only during an explicit
canonical deployment. Both installations are commit-pinned with automatic
updates disabled. Public repositories use the agent host's GitHub identity and
don't store a PAT in the recipe.

The current FinOps Toolkit marketplace plugin ships `finops-toolkit` but no
longer ships `azure-cost-management`. The recipe pins that skill from the
official standalone source at
[`src/templates/agent-skills/azure-cost-management`](https://github.com/microsoft/finops-toolkit/tree/57dece2be058228c6dca6d2e023ae652b7559fc6/src/templates/agent-skills/azure-cost-management)
instead of importing the 193+ unrelated skills in the broad Azure Agent Skills
plugin.

## Knowledge sources

The recipe defines 15 URL-backed knowledge items in
`data/knowledge-items.json`. Deployment creates them as `KnowledgeWebPage`
items through the SRE Agent data plane, which fetches and indexes each URL.

| Knowledge item | Source |
|---|---|
| `configure-cost-management-exports-for-finops-hubs` | [Configure scopes](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/configure-scopes) |
| `configure-finops-hubs-recommendations` | [Configure FinOps hubs recommendations](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/configure-recommendations) |
| `configure-private-networking-in-finops-hubs` | [Configure private networking in FinOps hubs](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/private-networking) |
| `tutorial:-create-and-update-finops-hubs` | [Create and update FinOps hubs](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/deploy) |
| `finops-hub-data-model` | [FinOps hubs data model](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/data-model) |
| `finops-hub-database-guide` | FinOps Toolkit query catalog database guide |
| `understanding-savings-calculations-in-finops-toolkit` | [Understanding savings calculations](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/savings-calculations) |
| `upgrade-a-finops-hubs-instance` | [Upgrade a FinOps hubs instance](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/upgrade) |
| `well-architected-capacity-planning` | [Well-Architected capacity planning](https://learn.microsoft.com/azure/well-architected/performance-efficiency/capacity-planning) |
| `well-architected-regions-and-zones` | [Well-Architected regions and availability zones](https://learn.microsoft.com/azure/well-architected/design-guides/regions-availability-zones) |
| `well-architected-disaster-recovery` | [Well-Architected disaster recovery](https://learn.microsoft.com/azure/well-architected/reliability/disaster-recovery) |
| `azure-quotas-overview` | [Azure Quotas overview](https://learn.microsoft.com/azure/quotas/quotas-overview) |
| `azure-capacity-reservations` | [On-demand capacity reservations](https://learn.microsoft.com/azure/virtual-machines/capacity-reservation-overview) |
| `azure-check-zone-peers` | [Check Zone Peers API](https://learn.microsoft.com/rest/api/resources/subscriptions/check-zone-peers?view=rest-resources-2022-12-01) |
| `aks-upgrade-capacity-planning` | [AKS upgrade capacity planning](https://learn.microsoft.com/azure/aks/upgrade-capacity-cost-planning) |

The Microsoft review site is authentication-gated documentation infrastructure,
not an agent connector or identity requirement. The recipe uses only public
Microsoft Learn URLs at runtime.

## Capacity resilience preflight

Run an on-demand preflight before a launch, onboarding wave, new deployment
stamp or region, AKS/VMSS upgrade or replacement, failover topology change,
disaster-recovery drill, large scale event, or allocation-failure retry:

> Ask `azure-capacity-manager` to run a read-only capacity resilience preflight
> for `<workload and scope>`. Return PASS, BLOCK, or INSUFFICIENT EVIDENCE.
> Model complete primary and recovery scale units, normal demand, upgrade or
> replacement surge, failover demand, VM and non-compute quota, subnet IP and
> load-balancer limits, SKU and region access, CRG coverage, fallback
> compatibility, zone mapping where subscriptions differ, evidence freshness,
> runway, owners, and escalation deadlines. Classify any allocation failure
> before recommending action. Do not submit requests or change resources.

Subscription-level evidence requires Reader access at each assessed
subscription. Target-resource-group Reader alone cannot establish
subscription quota or cross-subscription zone mapping. Missing or stale access
evidence must produce `INSUFFICIENT EVIDENCE`, not a guessed mapping.

## Refresh Kusto tools

Run the recipe-local generator after updating the FinOps Toolkit query catalog:

```bash
python3 recipes/finops-hubs/generate-kusto-tools.py \
  --catalog-dir /path/to/finops-toolkit/src/queries/catalog
```
