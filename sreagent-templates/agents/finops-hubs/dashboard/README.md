# Savings plans dashboard

This separate, local-only page uses live Azure Billing, Cost Management, and
FinOps Hub data. It does not change the cockpit or its Kusto bridge, and it is
not a hosted SRE Agent Live Report to upload.

With an active Azure CLI sign-in for the target tenant and billing profile,
configure the target environment (or let `AZURE_TENANT_ID` and
`AZURE_SUBSCRIPTION_ID` default to `az account show`, and `KUSTO_CLUSTER_URI`
default to `../connectors.json`) and run from the dashboard directory:

```powershell
$env:AZURE_TENANT_ID = "<tenant-id>"
$env:AZURE_SUBSCRIPTION_ID = "<subscription-id>"
$env:KUSTO_CLUSTER_URI = "https://<cluster>.<region>.kusto.windows.net"
$env:KUSTO_DATABASE = "Hub"

node serve-savings-plans.mjs
```

Open <http://127.0.0.1:4174/>. Refresh makes new read-only ARM and Kusto
requests; it does not reuse completed results. The server resolves the billing
profile from the configured subscription, then reads savings-plan inventory,
completed-day utilization, and Azure purchase recommendations. Observed
current-month coverage comes from the FinOps Hub `Costs()` and `Prices()`
functions; the recommendation-impact modeler uses Azure's evaluated commitments.
The bridge calls REST directly, not the hosted SRE Agent connector.

See `savings-plan-model.mjs` and `savings-plan-coverage.mjs` for the
calculations and eligibility joins.
