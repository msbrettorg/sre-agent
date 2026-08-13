# FinOps Hub MTD KPI Cockpit

This folder contains the FinOps Hub Live Report and a dependency-free local
preview bridge:

- `FinOps-Hub-MTD-KPI-Cockpit.html` is the portable Live Report uploaded to
  Azure SRE Agent.
- `build-local.mjs` generates an ignored local copy with the destination Kusto
  configuration and browser bridge.
- `serve-local.mjs` serves the local copy and proxies its Kusto queries.
- `live-sreagent.js` implements the hosted `window.sreagent` browser contract
  for local development.

The local preview uses live FinOps Hub data. It does not use fixtures, mocks, or
synthetic query results.

## Upload to Azure SRE Agent

The report requires the destination agent to expose and authorize the
`system-mcp-kusto_kusto_query` tool.

1. Make a working copy of `FinOps-Hub-MTD-KPI-Cockpit.html`.
2. In the copy, replace `REPLACE_WITH_FINOPS_HUB_CLUSTER_URI` with the FinOps
   Hub Azure Data Explorer cluster origin, such as
   `https://example.westus.kusto.windows.net`.
3. Do not append `/Hub`. The report already sets the database to `Hub`.
4. Upload the prepared copy to the deployed agent as a Live Report.

The placeholder is intentionally invalid so an unconfigured report fails
visibly instead of querying the source environment. Live Report publication is
a manual post-deployment step; `new-agent.sh` and `deploy.sh` do not publish it.

## Run locally

### Prerequisites

- Node.js 18 or later
- Azure CLI
- An Azure identity with query access to the FinOps Hub `Hub` database

Sign in to the tenant that contains the FinOps Hub:

```bash
az login --tenant <tenant-id>
```

From this directory, configure the destination and generate the local report:

```bash
export AZURE_TENANT_ID="<tenant-id>"
export KUSTO_CLUSTER_URI="https://<cluster>.<region>.kusto.windows.net"
export KUSTO_DATABASE="Hub"
export PORT="4174"

node build-local.mjs
node serve-local.mjs
```

Open <http://127.0.0.1:4174/>. The generated
`FinOps-Hub-MTD-KPI-Cockpit.local.html` is ignored by Git.

Run `node build-local.mjs` again after changing the source report or local
configuration. Restart `serve-local.mjs` after changing an environment
variable.

## How the local bridge works

The generated report injects a local implementation of:

```javascript
window.sreagent.callTool(...)
window.sreagent.getState()
window.sreagent.setState(...)
```

Browser state is stored in `localStorage`. Kusto calls are sent to the
loopback server, which obtains a short-lived Kusto token from the signed-in
Azure CLI session and submits each query to the Azure Data Explorer
`/v1/rest/query` endpoint. The token remains in the server process and is never
returned to browser code.

The server:

- Binds only to `127.0.0.1`.
- Allows only `system-mcp-kusto_kusto_query`.
- Locks requests to the configured cluster and database.
- Rejects Kusto management commands and oversized requests.
- Accepts requests only from the configured local origin.

Inspect local bridge calls in browser developer tools with:

```javascript
window.__sreagentLocal.calls
```

## Troubleshooting

| Symptom | Resolution |
|---|---|
| `KUSTO_CLUSTER_URI is required` | Export the cluster origin before running both scripts. |
| Azure CLI authentication error | Run `az login --tenant <tenant-id>` and confirm the identity can query the `Hub` database. |
| `The requested Kusto target is not allowed` | Rebuild the local report and restart the server with identical `KUSTO_CLUSTER_URI` and `KUSTO_DATABASE` values. |
| Dashboard panels show a Kusto error | Check the server output for the service error and verify database permissions and FinOps Hub ingestion. |
| Port already in use | Set `PORT` to an unused local port, rebuild, and restart the server. |

## References

- [Azure Data Explorer REST API overview](https://learn.microsoft.com/kusto/api/rest/?view=microsoft-fabric)
- [Azure Data Explorer authentication over HTTPS](https://learn.microsoft.com/kusto/api/rest/authentication?view=microsoft-fabric#get-an-access-token)
- [Azure SRE Agent MCP server](https://learn.microsoft.com/azure/sre-agent/mcp-server)
