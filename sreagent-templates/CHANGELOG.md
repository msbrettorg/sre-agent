# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- **MAJOR**: Breaking changes (new required params, changed agent.json format, removed recipes)
- **MINOR**: New features (new recipe, new deploy backend, new CLI flag)
- **PATCH**: Bug fixes, docs, test improvements

## [Unreleased]

### Changed
- Organized commitment recommendations by benefit type and service, with
  reservation term/lookback filters and separate Compute/Database savings-plan
  comparisons. Preserved source queries, financial amounts, and exact modeler
  Explore actions.
- Expanded the commitment dashboard to observed reservations across all
  services, with separate benefit counts, cost utilization, service spend
  shares, exact-meter native usage, and Azure Advisor reservation recommendations.
  Preserved the VM vCPU-hour proxy and savings-plan-only evaluated modeler.
- Labeled VM usage coverage in vCPU-hours and added separate reservation and
  savings-plan effective-cost amounts and spend-share percentages for the same
  cohort. Both sides of spend share use `EffectiveCost`; Azure modeled coverage
  is labeled separately on its pre-discount cost basis.
- Replaced the mixed-price compute cost ratio with an authored VM core-hour
  usage-coverage proxy. Reservations and savings plans are displayed separately,
  Spot is excluded, and source validation gates the returned percentage.
- Added observed commitment cost and waste dollars, an Azure-evaluated
  no-purchase/lower/highlighted decision comparison, and historical evaluation
  periods to the savings-plan report.
- Simplified all five desktop savings-plan views with consistent typography,
  larger metrics, readable financial tables, and compact modeler controls
  for executive review without external assets or dependencies.
- Removed operational badges, implementation details, and prescriptive
  approval messaging from the savings-plan report UI.
- Added the portable `FinOps-Hub-Savings-Plans.html` Live Report and local preview support in `live-reports/`.
- Added 15 live-tested FinOps Hub `Quota()` Kusto tools for quota usage,
  headroom, SKU restrictions, availability-zone mappings, and capacity
  inventory, assigned only to the FinOps Hub database specialist.
- Strengthened the `finops-hubs` capacity-resilience contract with deployable
  primary and recovery scale units, temporary demand, allocation-failure
  classification, AKS upgrade readiness, public Azure grounding, and a
  read-only cross-subscription zone-mapping tool.
- Made the `finops-hubs` capacity, cost-management, and FinOps Toolkit skills
  reproducible through the official azcapman marketplace, the FinOps Toolkit
  plugin's direct URL, and one pinned official standalone skill.
- Applied GitHub authentication before marketplace registration so public
  plugin sources resolve during unattended deployments.

### Fixed
- Made the local emulator return hosted text-content responses, enforce
  per-report tool approvals from a shared manifest, and preserve the hosted CSP
  and nonce. Updated both report parsers and aligned the recipe bridge with the
  agent bridge's existing Az PowerShell authentication and benefit-tool support.
- Added hosted text-content response handling to both portable savings-plan
  reports, preserving Kusto tables with incidental `result` fields and exposing
  response-key diagnostics. Documented required report tool approvals and the
  destination-agent save/version lifecycle.
- Removed the invalid `finops-hubs` MACC Kusto proxy and required all specialist
  agents to treat MACC billing-contract evidence as distinct from reservations,
  savings plans, capacity reservations, and commitment-discount analytics.
- Enabled every built-in Visualization and Log Query tool in the `finops-hubs`
  portal catalog through a separate built-in override payload, and corrected
  the global access policy to current runtime names including `KustoClient`.
- Required the FinOps Toolkit direct plugin installation to resolve and track
  the repository's `dev` branch instead of relying on an implicit default ref.
- Corrected the `finops-hubs` Azure Resource Manager MCP payload to use the
  endpoint-specific token scope and the platform's flattened
  `x-mcp-toolset: CostManagement` header shape with the agent's system-assigned
  managed identity.
- Added the FinOps Toolkit plugin's declared read-only Kusto stdio MCP
  connector so its connector requirement is provisioned with the recipe.
- Preserved the requested HTTP method in PowerShell data-plane calls so GitHub
  PAT configuration uses `PUT` instead of falling through to `POST`.
- Kept Azure CLI warnings separate from deployment JSON so successful ARM
  deployments aren't reported as failed.

### Testing
- Added focused four-backend dry-run coverage for the `finops-hubs` recipe.

## [1.0.0] — 2026-05-07

### Deploy Backends
- **Bicep** (`deploy.sh`) — ARM deployment via `az deployment sub create`
- **Terraform** (`deploy-tf.sh`) — azapi provider, per-agent workspaces, same config dir
- **PowerShell** (`Deploy-Agent.ps1`) — full PS7 port of all bash scripts
- **azd** (`azd up`) — Azure Developer CLI wrapper via hooks

### Recipes (3P)
- `azmon-lawappinsights` — Azure Monitor alert response with App Insights + Log Analytics
- `pagerduty-law-vmcosmos` — PagerDuty with VM, CosmosDB, HTTP error investigation
- `dynatrace-mcp` — Dynatrace MCP connector for app error investigation

### Core Scripts
- `new-agent.sh` / `New-Agent.ps1` — interactive or `--non-interactive` recipe setup
- `deploy.sh` / `deploy-tf.sh` / `Deploy-Agent.ps1` — multi-backend deploy
- `export-agent.sh` / `Export-Agent.ps1` — export live agent for cloning
- `verify-agent.sh` / `Verify-Agent.ps1` — 22-point post-deploy verification
- `diff-agent.sh` / `Diff-Agent.ps1` — compare config vs live agent
- `apply-extras.sh` / `Apply-Extras.ps1` — ARM sub-resources + data-plane config

### Infrastructure
- Bicep: `main.bicep` + `agent-core.bicep` + `agent-extensions.bicep`
- Terraform: `main.tf` + `variables.tf` + `outputs.tf` + `versions.tf`
- RBAC: system MI + UAMI roles on target RGs (Reader, Log Analytics Reader, Contributor)
- Connector timeouts: 10min guard for K8s extension install hangs

### Testing
- Dry-run test suite: 6 recipes × 4 backends (Bicep, TF, PS, azd-style)
- Content validation: skill specs, subagent handoffs, connector types, no unreplaced placeholders

### Fixes in this release
- ARM sub-resource migration for Cloud Shell compatibility
- System MI RBAC on target RGs (was missing — caused 403 on connector queries)
- Skill encoding for TF (restructured to match Bicep: name, description, tools, skillContent)
- KnowledgeFile connectors via apply-extras ARM PUT (not Bicep — avoids K8s hang)
- Region: removed hardcoded `eastus2` default, location now required
- Model provider: added prompt with Anthropic/GitHubCopilot/MicrosoftFoundry + EU data residency warning
- PS bugs: Get-ChildItem -Include, stderr in JSON parse, StrictMode safety, parameter mismatches
- Empty repo URL handling: skip GitHub auth prompt when no repo configured
- Recipe fixes: incident platform type casing, trailing commas, missing fields, expected-config.json connector lists

---

_When upgrading: check Breaking Changes section. If empty, upgrade is safe._
_To check your version: `cat VERSION`_
_To see what changed: `git log v<old>..v<new> --oneline`_
