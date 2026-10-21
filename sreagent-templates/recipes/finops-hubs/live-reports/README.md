# FinOps Hub Live Reports

This folder contains the portable FinOps Hub Live Reports and a dependency-free
local preview bridge:

- `FinOps-Hub-MTD-KPI-Cockpit.html` is the portable month-to-date KPI cockpit
  Live Report uploaded to Azure SRE Agent.
- `FinOps-Hub-Savings-Plans.html` is the portable savings-plan utilization,
  VM vCPU-hour coverage, effective-cost spend share, and Azure-evaluated
  decision comparison Live Report.
  Observed costs do not establish purchased-plan inventory.
- `build-local.mjs` generates ignored `.local.html` copies of both reports with
  the destination Kusto configuration and browser bridge.
- `serve-local.mjs` serves the local copies and proxies their Kusto queries.
- `live-sreagent.js` implements the hosted `window.sreagent` browser contract
  for local development.
- `local-reports.json` defines each local report's routes and approved
  `allowedTools`, shared by the generator and server.

The local preview uses live FinOps Hub data. It does not use fixtures, mocks, or
synthetic query results.

### VM usage coverage and spend share

The report uses an authored quantity-based query: benefit-backed consumed
vCPU-hours divided by total consumed vCPU-hours for selected Virtual Machines,
Virtual Machine Scale Sets, and Batch CPU meters over 30 completed UTC days.
Coverage labels usage in vCPU-hours and shows reservation-backed and
savings-plan-backed hours separately, with combined usage coverage in Summary.
Billing accounts, profiles, and currencies
remain separate. Spot, license, ancillary, purchase, and unused-commitment
accounting rows are excluded from the displayed consumption proxy.

The browser displays the query's returned percentage. Invalid quantities,
conversions, benefit attribution, or exact duplicate rows make the affected
result unavailable. This is not all-eligible Compute coverage, portable
savings-plan capacity, or commitment utilization. Eligibility fields and charge
IDs are not populated in the verified source, so no eligibility or billing-line
uniqueness claim is made.

This is not the unchanged Toolkit
[`compute-spend-commitment-coverage.kql`](https://github.com/microsoft/finops-toolkit/blob/dev/src/queries/catalog/compute-spend-commitment-coverage.kql):
that query's discounted-cost ratio is not used as usage coverage.

Spend share uses the same selected VM cohort, period, billing scope, and currency:
reservation-backed and savings-plan-backed `EffectiveCost` divided by total
`EffectiveCost`. Both sides use the same amortized effective-cost basis.
Coverage shows reservation dollars, savings-plan dollars, total spend, and their
combined spend share separately from vCPU-hours. Currency symbols follow each
scope's billing currency; no currency conversion or cross-scope averaging occurs.
This is observed spend attribution, not usage coverage, savings, or pre-discount
eligible-usage coverage. Purchase and unused-commitment costs remain excluded.
Missing, nonfinite, negative, or inconsistent costs and a zero cost denominator
make spend share unavailable independently of valid vCPU-hour coverage.

Azure modeled coverage is labeled separately on its evaluated pre-discount
cost-without-benefit basis. It is not a like-for-like comparison with either
observed VM metric.

### CFO review

Observed utilization includes used, unused, and total amortized commitment costs
and waste percentages for 7 and 30 completed UTC days. These follow the Toolkit
commitment-discount waste/utilization definitions, exclude commitment purchases,
and retain account, billing profile, currency, and reported-day counts.
Unrecognized allocation statuses or invalid costs make that window unavailable.

Recommendations compare no additional purchase with the lowest positive
Azure-evaluated commitment below each highlighted recommendation, when one is
returned, and the highlighted one-year and three-year alternatives. Explore
opens the exact selected scenario in the modeler. Each evaluated row shows its
historical period, hourly amount, total cost, savings, and waste; waste is already
included in total cost. No additional purchase means zero new commitment, not
zero portfolio cost. No portfolio baseline or future forecast is synthesized.

The current tools do not return existing contractual hourly commitment, expiry,
or combined obligations. Missing fields remain unavailable rather than inferred.

## Upload to Azure SRE Agent

Both reports require the destination agent to expose and authorize the
`system-mcp-kusto_kusto_query` tool.

The savings-plan report also requires
`azure-resource-manager-mcp_get_benefit_recommendations` and
`azure-resource-manager-mcp_list_benefit_utilization`. All three tools must be
included in the saved report's approved `allowedTools` list. The report calls
`window.sreagent.callTool(...)` at view time; local emulator access does not
establish access for the hosted report.

1. Make a working copy of `FinOps-Hub-MTD-KPI-Cockpit.html` or
   `FinOps-Hub-Savings-Plans.html`.
2. In the copy, replace `REPLACE_WITH_FINOPS_HUB_CLUSTER_URI` with the FinOps
   Hub Azure Data Explorer cluster origin, such as
   `https://example.westus.kusto.windows.net`.
3. Do not append `/Hub`. Each report already sets the database to `Hub`.
4. Attach the prepared source to the destination agent's Live Report authoring
   thread and save it as a Live Report with the required tool approvals.

For a new report, omit `reportId` when saving. To update an existing report,
use its existing `reportId` and checked-out HTML path to save a new version.
Open the current saved version and confirm that its panels load. A source HTML
file or a local preview is not a published report, and a copied report link
does not transfer the report or its tool approvals to another agent.

Keep the hosted content security policy and `nonce="{REPORT_NONCE}"` on the
script. Connector results are rendered as text, not injected as HTML. The
report parsers support Kusto header-plus-positional-row tables and hosted
text-content wrappers, including `type`/`$type`, top-level `text`, and
`additionalProperties.results.items`. Tool errors remain visible failures.

The placeholder is intentionally invalid so an unconfigured report fails
visibly instead of querying the source environment. Live Report publication is
a manual post-deployment step; `Deploy-Agent.ps1` does not publish it.

## Run locally

### Prerequisites

- Node.js 18 or later
- PowerShell 7 with the `Az.Accounts` module
- An Azure identity with query access to the FinOps Hub `Hub` database

Use an existing signed-in Az PowerShell context for the destination tenant and
subscription. The bridge selects that exact context with `-DefaultProfile`; it
does not sign in or change the current context.

From this directory, configure the destination and generate the local reports:

```powershell
$env:AZURE_TENANT_ID = "<tenant-id>"
$env:AZURE_SUBSCRIPTION_ID = "<subscription-id>"
$env:KUSTO_CLUSTER_URI = "https://<cluster>.<region>.kusto.windows.net"
$env:KUSTO_DATABASE = "Hub"
$env:PORT = "4174"

node build-local.mjs
node serve-local.mjs
```

Open:

- <http://127.0.0.1:4174/> for `FinOps-Hub-MTD-KPI-Cockpit.local.html`
- <http://127.0.0.1:4174/savings-plans> for `FinOps-Hub-Savings-Plans.local.html`

The generated `*.local.html` files are ignored by Git.

Run `node build-local.mjs` again after changing a source report or local
configuration. Restart `serve-local.mjs` after changing an environment
variable or `local-reports.json`.

## How the local bridge works

The generated report injects a local implementation of:

```javascript
window.sreagent.callTool(...)
window.sreagent.getState()
window.sreagent.setState(...)
```

Browser state is stored in `localStorage`. Kusto calls are sent to the
loopback server, which obtains a short-lived Kusto token from the selected
Az PowerShell context and submits each query to the Azure Data Explorer
`/v1/rest/query` endpoint. The token remains in the server process and is never
returned to browser code.

The server:

- Binds only to `127.0.0.1`.
- Enforces each report's `allowedTools` from `local-reports.json`, in both the
  browser SDK and server. The MTD cockpit allows Kusto only; savings plans also
  allows benefit recommendations and utilization with their supported arguments.
- Returns the hosted `$type: "text"` envelope with JSON in `text`, rather than
  exposing the unwrapped result table. Both portable reports must parse that
  response on every view-time call.
- Retains the source CSP and substitutes the same generated nonce into its
  policy and scripts. A missing hosted CSP or application nonce fails the build.
- Locks requests to the configured cluster and database.
- Rejects Kusto management commands and oversized requests.
- Accepts requests only from the configured local origin.

Azure benefit reads use a separate ARM token for the same explicit context.
The recipe and agent bridges use the same implementation. All financial data
still comes from the configured Hub and Azure APIs.

The emulator reproduces the view-time tool contract, not the SRE Agent report
store. Saving, `reportId`, version history, connector permissions, and actual
hosted tool approvals still belong to the destination agent. Local success
does not establish that a report is published or that its agent can access data.

Inspect local bridge calls in browser developer tools with:

```javascript
window.__sreagentLocal.calls
window.__sreagentLocal.allowedTools
```

## Troubleshooting

| Symptom | Resolution |
|---|---|
| `KUSTO_CLUSTER_URI is required` | Set the cluster origin before running both scripts. |
| Az PowerShell context error | Confirm exactly one existing context matches `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`, and that its identity can access the Hub and required billing profile. |
| Tool is not approved for report | Check `local-reports.json`, then rebuild the reports and restart the server. This does not grant tool approval on a hosted agent. |
| `The requested Kusto target is not allowed` | Rebuild the local report and restart the server with identical `KUSTO_CLUSTER_URI` and `KUSTO_DATABASE` values. |
| Dashboard panels show a Kusto error | Check the server output for the service error and verify database permissions and FinOps Hub ingestion. |
| Port already in use | Set `PORT` to an unused local port, rebuild, and restart the server. |

## References

- [Azure Data Explorer REST API overview](https://learn.microsoft.com/kusto/api/rest/?view=microsoft-fabric)
- [Azure Data Explorer authentication over HTTPS](https://learn.microsoft.com/kusto/api/rest/authentication?view=microsoft-fabric#get-an-access-token)
- [Azure SRE Agent MCP server](https://learn.microsoft.com/azure/sre-agent/mcp-server)
