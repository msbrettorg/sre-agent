const supportedSkus = ["Compute_Savings_Plan", "Database_Savings_Plan"];

export function coverageQuery(profileId, period) {
  const scope = /^\/providers\/Microsoft\.Billing\/billingAccounts\/([a-f0-9:._-]+)\/billingProfiles\/([a-z0-9-]+)$/i.exec(profileId);
  if (!scope || !/^\d{4}-\d{2}-\d{2}$/.test(period.from) || !/^\d{4}-\d{2}-\d{2}$/.test(period.to)) {
    throw new Error("Coverage requires a verified billing profile and UTC reporting period.");
  }
  const end = new Date(`${period.to}T00:00:00Z`);
  end.setUTCDate(end.getUTCDate() + 1);
  const to = end.toISOString().slice(0, 10);
  return `let usage = materialize(
Costs()
| where ChargePeriodStart >= datetime(${period.from}) and ChargePeriodStart < datetime(${to})
| where x_BillingAccountId =~ '${scope[1]}' and x_BillingProfileId =~ '${scope[2]}'
| where ChargeCategory == 'Usage' and CommitmentDiscountStatus != 'Unused'
| where PricingCategory != 'Dynamic'
| extend Day = startofday(ChargePeriodStart), Meter = tolower(x_SkuMeterId)
| summarize Records = count(), Contracted = sum(ContractedCost),
    AbsoluteContracted = sum(abs(ContractedCost)), MissingContracted = countif(isnull(ContractedCost)),
    Effective = sum(EffectiveCost), BenefitIds = make_set_if(CommitmentDiscountId, CommitmentDiscountType == 'Savings Plan' and CommitmentDiscountStatus == 'Used', 100)
    by Day, Meter, BillingCurrency, CommitmentDiscountType, CommitmentDiscountStatus);
let priceWindows =
Prices()
| where x_BillingAccountId =~ '${scope[1].split(":")[0]}' and x_BillingProfileId =~ '${scope[2]}'
| where x_EffectivePeriodStart < datetime(${to}) and x_EffectivePeriodEnd > datetime(${period.from})
| extend Meter = tolower(x_SkuMeterId)
| where isnotempty(Meter) and Meter in (usage | distinct Meter)
| extend PlanKind = case(
    x_SkuPriceType != 'SavingsPlan', '',
    x_SkuServiceFamily == 'Databases', 'Database_Savings_Plan',
    x_SkuMeterCategory == 'Virtual Machines Licenses' and x_SkuDescription contains 'SQL', 'Database_Savings_Plan',
    x_SkuServiceFamily == 'Compute' and x_SkuMeterCategory != 'Virtual Machines Licenses', 'Compute_Savings_Plan',
    x_SkuMeterCategory in ('Container Instances', 'Azure Spring Cloud'), 'Compute_Savings_Plan',
    'Unclassified')
| summarize HasCompute = max(toint(PlanKind == 'Compute_Savings_Plan')),
    HasDatabase = max(toint(PlanKind == 'Database_Savings_Plan')),
    HasUnclassified = max(toint(PlanKind == 'Unclassified'))
    by Meter, BillingCurrency, PriceStart = x_EffectivePeriodStart, PriceEnd = x_EffectivePeriodEnd;
usage
| join kind=leftouter priceWindows on Meter, BillingCurrency
| extend ValidPrice = isnotnull(PriceStart) and Day >= PriceStart and Day < PriceEnd
// Collapse price versions and terms before summing usage so the join cannot multiply cost.
| summarize PriceMatched = max(toint(ValidPrice)),
    ComputeEligible = max(toint(ValidPrice and HasCompute == 1)),
    DatabaseEligible = max(toint(ValidPrice and HasDatabase == 1)),
    Unclassified = max(toint(ValidPrice and HasUnclassified == 1)),
    Records = take_any(Records), Contracted = take_any(Contracted),
    AbsoluteContracted = take_any(AbsoluteContracted), MissingContracted = take_any(MissingContracted),
    Effective = take_any(Effective), BenefitIds = take_any(BenefitIds)
    by Day, Meter, BillingCurrency, CommitmentDiscountType, CommitmentDiscountStatus
| extend PlanKind = case(
    Unclassified == 1 or (ComputeEligible == 1 and DatabaseEligible == 1), 'Unclassified',
    ComputeEligible == 1, 'Compute_Savings_Plan',
    DatabaseEligible == 1, 'Database_Savings_Plan',
    PriceMatched == 1, 'Ineligible', 'Missing prices')
| extend IsSavingsPlan = CommitmentDiscountType == 'Savings Plan' and CommitmentDiscountStatus == 'Used',
    IsReservation = CommitmentDiscountType == 'Reservation' and CommitmentDiscountStatus == 'Used'
| summarize Records = sum(Records), EligibleCost = sum(Contracted),
    AbsoluteCost = sum(AbsoluteContracted), MissingContracted = sum(MissingContracted),
    CoveredCost = sumif(Contracted, IsSavingsPlan),
    ReservedCost = sumif(Contracted, IsReservation),
    CoveredEffectiveCost = sumif(Effective, IsSavingsPlan),
    CoveredRecords = sumif(Records, IsSavingsPlan),
    FirstUsage = min(Day), LastUsage = max(Day), UsageDays = make_set(Day, 32),
    BenefitSets = make_set_if(BenefitIds, IsSavingsPlan, 100)
    by PlanKind, BillingCurrency
| order by PlanKind asc, BillingCurrency asc`;
}

export function normalizeCoverage(rows, period, inventory) {
  if (!Array.isArray(rows) || !rows.length) throw new Error("The Hub returned no usage for the billing profile.");
  const plans = new Map(inventory.map((plan) => [plan.id.toLowerCase(), plan]));
  const seen = new Set();
  let lastDay = "";
  let zeroCostUnmatchedRecords = 0;
  for (const row of rows) {
    const key = `${row.PlanKind}:${row.BillingCurrency}`;
    if (seen.has(key)) throw new Error("The Hub returned duplicate coverage groups.");
    seen.add(key);
    if (!/^[A-Z]{3}$/.test(row.BillingCurrency) || row.MissingContracted !== 0 ||
        !Number.isFinite(row.AbsoluteCost) || !Number.isFinite(row.EligibleCost) ||
        !Number.isFinite(row.CoveredCost) || !Number.isFinite(row.ReservedCost) ||
        !Number.isFinite(row.CoveredRecords)) {
      throw new Error("Hub coverage has missing or invalid currency, cost, or usage fields.");
    }
    const day = row.LastUsage?.slice(0, 10);
    if (!day || day < period.from || day > period.to) throw new Error("Hub coverage is outside the requested period.");
    if (day > lastDay) lastDay = day;
    if (["Missing prices", "Unclassified"].includes(row.PlanKind)) {
      if (row.AbsoluteCost > 0.000001 || row.CoveredRecords > 0) {
        throw new Error(`Cannot calculate complete coverage: ${row.PlanKind.toLowerCase()} for billable usage.`);
      }
      zeroCostUnmatchedRecords += row.Records;
    } else if (row.PlanKind === "Ineligible" && row.CoveredRecords > 0) {
      throw new Error("Applied savings-plan usage conflicts with the customer price-sheet eligibility.");
    } else if (!["Ineligible", ...supportedSkus].includes(row.PlanKind)) {
      throw new Error("The Hub returned an unsupported eligibility classification.");
    }
  }
  const metrics = rows.filter((row) => supportedSkus.includes(row.PlanKind)).map((row) => {
    const eligibleCost = row.EligibleCost - row.ReservedCost;
    if (eligibleCost < -0.000001 || row.CoveredCost < -0.000001 ||
        row.CoveredCost > eligibleCost + 0.000001) {
      throw new Error("Covered usage does not reconcile with eligible on-demand-equivalent usage.");
    }
    const ids = [...new Set((row.BenefitSets || []).flat())];
    for (const id of ids) {
      const plan = plans.get(id.toLowerCase());
      if (!plan || plan.sku !== row.PlanKind) {
        throw new Error("Applied savings-plan usage does not match the purchased plan inventory.");
      }
    }
    return {
      sku: row.PlanKind, currency: row.BillingCurrency,
      status: eligibleCost > 0 ? "ready" : "no-eligible-usage",
      percent: eligibleCost > 0 ? 100 * row.CoveredCost / eligibleCost : null,
      coveredCost: row.CoveredCost, eligibleCost,
      uncoveredCost: eligibleCost - row.CoveredCost,
      reservedCost: row.ReservedCost, records: row.Records,
      from: row.FirstUsage.slice(0, 10), to: row.LastUsage.slice(0, 10),
      usageDays: row.UsageDays.length, benefitIds: ids,
    };
  });
  if (!metrics.length) throw new Error("No eligible usage was identified in the customer's price sheet.");
  return {
    status: "ready", metrics, period, dataThrough: lastDay,
    zeroCostUnmatchedRecords,
    basis: "Negotiated on-demand-equivalent cost (ContractedCost)",
    eligibility: "Customer price-sheet savings-plan prices, matched by meter, currency, and effective period",
    exclusions: "Purchases, unused commitment, Spot usage, and reservation-covered usage",
  };
}
