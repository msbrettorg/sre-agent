# FinOps Hubs

Deploy an Azure SRE Agent for FinOps Hubs cost analytics and FinOps operations.

## Prerequisites

- A deployed FinOps Hub with an Azure Data Explorer endpoint
- At least one Azure resource group to monitor
- All [CLI tools](../../README.md#prerequisites) installed
- A Microsoft Teams account for post-deployment connector authorization

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
`AzureARM` authentication and does not require interactive user authentication
or stored credentials.

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
| **Connectors** | FinOps Hub Kusto, Microsoft Teams, and Azure Resource Manager HTTP MCP connectors; Teams requires interactive authorization and ARM MCP uses the agent system-assigned managed identity |
| **Tools** | FinOps Kusto and Python tools plus 14 explicitly selected Cost Management and Pricing MCP tools |
| **Subagents** | FinOps, finance, capacity, database, and hub specialists |
| **Automations** | Scheduled FinOps and capacity operations |
| **Knowledge** | Eight FinOps Hubs deployment, configuration, data model, database, savings, and upgrade guides |

The Azure Resource Manager MCP connector is generated from the recipe with the
`CostManagement,Pricing` toolset header, `AzureARM` authentication, and the
agent's system-assigned managed identity. `create_budget` remains governed by
the agent's **Review** action mode and is not included in the global auto-allow
policy.

## Knowledge sources

The recipe defines eight URL-backed knowledge items in
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

## Refresh Kusto tools

Run the recipe-local generator after updating the FinOps Toolkit query catalog:

```bash
python3 recipes/finops-hubs/generate-kusto-tools.py \
  --catalog-dir /path/to/finops-toolkit/src/queries/catalog
```
