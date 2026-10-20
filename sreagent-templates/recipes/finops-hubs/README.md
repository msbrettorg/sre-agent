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

The complete recipe requires a Hub. For customers without one, including those
using third-party cost tools, see [Deploy without a FinOps Hub](#deploy-without-a-finops-hub).
For a private Hub, complete [Private networking](#private-networking) before deployment.
Run the following commands from `sreagent-templates/`.

## Quick Start

Generate an agent configuration:

```powershell
./bin/ps/New-Agent.ps1 -Recipe finops-hubs -NonInteractive `
  -Set @{ agentName = 'finops-hubs-sre'; resourceGroup = 'finops-hubs-sre'
          location = 'eastus2'; targetRGs = 'finops-hubs-demo'
          finopsHubClusterUri = 'https://example.westus.kusto.windows.net/Hub' } `
  -Output agents/finops-hubs/
```

Deploy the generated configuration:

```powershell
./bin/ps/Deploy-Agent.ps1 -InputPath agents/finops-hubs/
```

For Bash Cloud Shell, keep the same generated config directory and use
`./bin/deploy.sh agents/finops-hubs/`. The Bash deployer requires PowerShell 7
and the Az PowerShell modules to run the checked-in `bicep/Apply-Extras.ps1`
after ARM deployment. It checks these requirements before changing Azure
resources. It doesn't switch your subscription or sign you in; select the
intended subscription yourself. If extras or verification fails, the command
returns nonzero even when ARM reports success.

Review `agent.json` and `expected-config.json` before deployment. In particular,
the verification spec's `agent.defaultModelProvider` must match the provider
you selected; the checked-in spec currently expects `MicrosoftFoundry`.
Keep intentional settings in the spec rather than weakening failing checks.

## Expected deployment output

The following is an illustrative excerpt, not a recorded deployment. Counts
refer to an unmodified recipe; exported or customized configurations can differ.

```text
  Bicep (ARM) resources:
    ✓ Connector: finops-hub-kusto (Kusto)
    ✓ Connector: azure-resource-manager-mcp (Mcp)
    ✓ Connector: azure-mcp-server (Mcp)

  Data-plane (apply-extras):
    ✓ Skills: 1
    ✓ Subagents: 5
    ✓ Tools: 51
    ✓ Common prompts: 1
    ✓ Scheduled tasks: 19
    ✓ Knowledge files: 15

─────────────── ARM deployment succeeded ───────────────
── Applying data-plane config (extras) ──
Data-plane:     token available
...
── Post-deploy verification ──
  Check                     Actual     Expected   Result
  Agent exists              yes        yes        ✅ PASS
  Required skills           3          3          ✅ PASS
  Subagents                 5          5          ✅ PASS
  Scheduled Tasks (unique)  19         19          ✅ PASS
```

Interpret each stage separately:

| Output | Meaning |
|---|---|
| Pre-deployment `✓` entries | Included in the assembled input, **not yet deployed**. Categories with zero items aren't printed. |
| `ARM deployment succeeded` | ARM infrastructure completed. Extras, plugin installs, authorization, and verification still follow. |
| Extras `ok` or an explicit success message | That configuration operation completed. Check each category, including the two plugin installations and Microsoft Teams ConnectorV2, which aren't listed in the preflight summary. |
| Connector `Succeeded` | ARM reports the connector provisioned. This doesn't prove a query works, the caller can obtain a data-plane token, or Teams is authorized. |
| `WARNING`, `skipped`, `FAILED`, or `❌ FAIL` | Read the affected item and error. Don't treat it as a complete recipe deployment. |
| Verification `✅ PASS` | That named check matched `expected-config.json`. The verifier doesn't cover every asset or test end-to-end Hub queries, Teams delivery, or private connectivity. |

The one local skill and two plugin-provided skills make three required runtime
skills. The 15 knowledge items and other pre-existing connectors can increase
the final ARM connector count beyond the three explicitly configured connectors.
Inspect the extras output and the portal for assets not covered by verification.
Deployment logs are written to `agents/finops-hubs/deploy-<timestamp>.log`;
save the complete terminal output as well because that log doesn't include every
extras operation. `Deployment complete` is printed only after the required
stages succeed; it doesn't imply that optional OAuth authorization is complete.

### Cloud Shell data-plane token failure

An Azure SRE data-plane token failure means Az PowerShell couldn't obtain a token
for the **deploying user's session**, with audience `https://azuresre.dev`.
It isn't a test of the connectors' managed identities. The verifier now prints
the Az PowerShell diagnostic instead of hiding it and returns a nonzero exit code.
Both deploy entrypoints return nonzero if extras or post-deployment verification
fails, even if ARM deployment succeeded. Skipped data-plane items make an
automatic deployment incomplete; standalone `Apply-Extras.ps1` still reports
skipped optional items without requiring completion.

The call order is ARM deployment, extras application, connector health, and
verification. A token failure in verification doesn't roll back existing
resources. However, extras probes the same audience earlier: if the token was
unavailable then, it skips data-plane-only items, including skills, subagents,
tools, plugins, and knowledge items. Healthy ARM connectors can coexist with
an incomplete agent. Review the extras warnings, not just the final error.

From an approved interactive PowerShell environment, authenticate for that
audience and select the intended subscription:

```powershell
$subscription = '<subscription-id>'
Connect-AzAccount
Set-AzContext -SubscriptionId $subscription -Scope Process
./bin/ps/Verify-Agent.ps1 -Subscription $subscription `
  -ResourceGroup '<agent-resource-group>' -AgentName '<agent-name>' `
  -Expected agents/finops-hubs/
```

If extras reported skipped items, rerun the canonical deployment after fixing
authentication, then verify again:

```powershell
./bin/ps/Deploy-Agent.ps1 -InputPath agents/finops-hubs/ -Force
```

Use the printed Az PowerShell error to distinguish sign-in, consent, tenant policy,
and other authentication failures. If Cloud Shell can't obtain the token, use
an approved local environment or have the tenant administrator review the error;
don't bypass policy. Token acquisition failure alone is not evidence of delayed
connector provisioning or missing Hub permissions. A later HTTP 401/403,
network error, or configuration mismatch is a separate verification failure
and remains a failure.

## Deploy to an existing SRE Agent

There is no `existingAgentId` or extras-only flag in this recipe. `Deploy-Agent.ps1`
updates the agent at the same subscription, resource group, and name. It still
reconciles infrastructure and configuration; this isn't an additive-only import.
An existing UAMI or Application Insights ID refers to a supporting resource,
not to the agent.

First select the correct Az PowerShell subscription and export the current agent
for reference. Don't change its identity with export's clone `--set` options:

```powershell
$subscription = '<existing-subscription-id>'
$resourceGroup = '<existing-agent-resource-group>'
$agentName = '<existing-agent-name>'
Set-AzContext -SubscriptionId $subscription -Scope Process
./bin/ps/Export-Agent.ps1 -Subscription $subscription `
  -ResourceGroup $resourceGroup -AgentName $agentName `
  -Output agents/existing-agent-backup/
```

Generate a separate FinOps configuration using the existing values:

```powershell
./bin/ps/New-Agent.ps1 -Recipe finops-hubs -NonInteractive `
  -Set @{
    agentName = $agentName
    resourceGroup = $resourceGroup
    location = '<existing-agent-region>'
    targetRGs = '<existing-monitored-resource-groups>'
    existingUamiId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity>'
    existingAgentAppInsightsId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/components/<app-insights>'
    modelProvider = '<existing-model-provider>'
    finopsHubClusterUri = 'https://<cluster>.<region>.kusto.windows.net/Hub'
  } -Output agents/existing-finops/
```

Preserve the existing managed identity, telemetry, access mode, model, network
settings, tags, and monitoring scope when reviewing the generated `agent.json`;
don't assume the export captures every setting. Reconcile it with the current
portal configuration and the backup. `targetRGs` is the complete desired scope,
not just additional groups. Review name collisions in connectors, tools, skills,
and scheduled tasks. A same-name item can be updated.

**Stop if the intended existing state can't be represented by the canonical
configuration.** For example, this Bicep model builds monitoring scope from
resource-group names; it can't round-trip arbitrary subscription-level managed
resources. Export isn't a complete backup of the live resource. Neither
successful change detection nor a dry run proves the update preserves all
existing state.

Update `expected-config.json` to reflect the intended combined configuration and
provider. Then use the canonical lifecycle:

```powershell
./bin/ps/Diff-Agent.ps1 -Subscription $subscription `
  -ResourceGroup $resourceGroup -AgentName $agentName -ConfigDir agents/existing-finops/
./bin/ps/Deploy-Agent.ps1 -InputPath agents/existing-finops/ -DryRun
./bin/ps/Deploy-Agent.ps1 -InputPath agents/existing-finops/
./bin/ps/Verify-Agent.ps1 -Subscription $subscription `
  -ResourceGroup $resourceGroup -AgentName $agentName -Expected agents/existing-finops/
```

Change detection returns nonzero when it finds differences; review them before
deploying. `--dry-run` assembles and inspects current state but doesn't deploy.
The scripts use the active Az PowerShell subscription for deployment, so keep it
aligned with `agent.json.identity.subscription`.

`bin/ps/Add-Recipe.ps1 -Recipe finops-hubs -AgentDir <exported-directory>` is the
repository's additive merge helper, but it **doesn't install the complete
FinOps Hubs recipe**: it doesn't copy plugin registrations/installations,
ConnectorV2, nested skill reference files, knowledge items, roles, built-in tool
settings, or the verification spec. Don't treat its success as full recipe
readiness. The full generated-configuration path above includes those assets,
but still requires the existing-state review.

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

The repository supports agent VNet integration through `agent.json`.
It doesn't provision a FinOps Hub private endpoint, private DNS zones, peering,
routes, or firewall rules for this recipe. Have the network owner establish
the private connectivity and DNS path for VNet-routed sandbox/tool traffic first.
This doesn't remove the connector limitation. See the linked
[FinOps Hubs private-networking guide](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/private-networking)
for the Hub side and the repository's
[VNet-integrated example](../../examples/vnet-integrated-keyvault/README.md)
for how agent subnet integration and private DNS fit together; that example
targets Key Vault and doesn't establish private Hub connector support.

For the supported agent egress configuration, add the existing fields to
`agent.json` after generation:

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

The assembler maps `type: vnet` to `egressMode: AzureVNet`, passes `subnetId`
as `vnetSubnetId`, and passes the private-DNS setting to Bicep. The canonical
deploy script can create a missing agent subnet or add its delegation; it does
not create the VNet or the Hub networking. Its default subnet prefix is `/28`,
which is smaller than the current documented minimum. Use a prepared `/27` or
larger subnet to avoid that default and unintended network changes.

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
connector `Succeeded` nor `Verify-Agent.ps1` proves end-to-end private query
access. VNet integration is egress-only, not a private inbound agent endpoint.

## Deploy without a FinOps Hub

**The complete `finops-hubs` recipe isn't a supported no-Hub deployment.**
Its generator requires `finopsHubClusterUri`, its verification spec requires
`finops-hub-kusto`, and its tools and tasks expect Hub functions such as
`Costs()`, `Prices()`, `Recommendations()`, and `Transactions()`. An empty or
dummy URI doesn't turn it into a no-Hub variant.

To deploy an SRE Agent without a Hub, use the existing minimal recipe:

```powershell
./bin/ps/New-Agent.ps1 -Recipe minimal -NonInteractive `
  -Set @{ agentName = 'finops-base-sre'; resourceGroup = 'finops-base-sre'
          location = 'eastus2'; targetRGs = '<resource-groups-to-monitor>' } `
  -Output agents/finops-base/
./bin/ps/Deploy-Agent.ps1 -InputPath agents/finops-base/
```

This deploys the minimal agent, **not** the FinOps Hubs skills, MCP connectors,
tools, reports, or 19 scheduled tasks. It doesn't read a third-party FinOps
product. This repository defines no no-Hub FinOps recipe, switch, or third-party
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
