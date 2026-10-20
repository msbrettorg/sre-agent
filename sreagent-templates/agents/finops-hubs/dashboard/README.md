# Savings plans dashboard

This separate, local-only page uses live Azure Billing, Cost Management, and
Sitecore FinOps Hub data. It does not change the cockpit or its Kusto bridge,
and it is not a hosted SRE Agent Live Report to upload.

With the existing Azure CLI sign-in for the Sitecore tenant and billing profile,
run this from the dashboard directory in PowerShell:

```powershell
node serve-savings-plans.mjs
```

Open <http://127.0.0.1:4174/>. Refresh makes new read-only ARM and Kusto
requests; it does not reuse completed results. The server resolves the billing
profile from the configured subscription, then reads savings-plan inventory,
completed-day utilization, and Azure purchase recommendations. Observed
current-month coverage comes from the Sitecore Hub `Costs()` and `Prices()`
functions; the recommendation-impact modeler uses Azure's evaluated commitments.
The bridge calls REST directly, not the hosted SRE Agent connector.

The four source files in this directory are copied unchanged from the local
preview. See `savings-plan-model.mjs` and `savings-plan-coverage.mjs` for the
calculations and eligibility joins.
