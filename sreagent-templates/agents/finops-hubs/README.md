# FinOps Hubs

Deploy an Azure SRE Agent for FinOps Hubs cost analytics and FinOps operations.

## Prerequisites

- A deployed FinOps Hub with an Azure Data Explorer endpoint
- At least one Azure resource group to monitor
- All [CLI tools](../../README.md#prerequisites) installed
- A Microsoft Teams account for post-deployment connector authorization
- SRE Agent Author or Administrator access to install public marketplace plugins
- Reader access for the agent identity on every subscription assessed for quota,
  capacity, or cross-subscription availability-zone mapping

## Quick Start

Generate an agent configuration:

```bash
./bin/new-agent.sh --recipe finops-hubs --non-interactive \
  --set agentName=finops-hubs-sre \
  --set resourceGroup=finops-hubs-sre \
  --set location=eastus2 \
  --set targetRGs=finops-hubs-demo \
  --set finopsHubClusterUri=https://example.westus.kusto.windows.net/Hub \
  -o agents/finops-hubs/
```

Deploy the generated configuration:

```bash
./bin/deploy.sh agents/finops-hubs/
```

## Post-deployment setup

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

### Set up the FinOps Hub Live Report

See the [Live Report README](live-reports/README.md) for preparation, manual
upload, and local live-data preview instructions.

## Parameters

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
