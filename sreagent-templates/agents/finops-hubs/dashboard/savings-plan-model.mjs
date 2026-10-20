export function skuLabel(sku) {
  return ({ Compute_Savings_Plan: "Compute", Database_Savings_Plan: "Database" })[sku] || sku;
}

export function termLabel(term) {
  return ({ P1Y: "1 year", P3Y: "3 years" })[term] || term;
}

function number(value, name, minimum = 0) {
  if (!Number.isFinite(value) || value < minimum) throw new Error(`Invalid ${name} in Azure recommendation.`);
  return value;
}

function percent(value, name) {
  number(value, name, -0.000001);
  if (value > 100.000001) throw new Error(`Invalid ${name} in Azure recommendation.`);
  return Math.max(0, Math.min(100, value));
}

export function normalizeRecommendation(record) {
  const p = record.properties;
  if (!record.id || !p || !["P1Y", "P3Y"].includes(p.term) ||
      !p.armSkuName || !/^[A-Z]{3}$/.test(p.currencyCode) ||
      p.scope !== "Shared" || p.commitmentGranularity !== "Hourly" ||
      !Number.isFinite(Date.parse(p.firstConsumptionDate)) ||
      !Number.isFinite(Date.parse(p.lastConsumptionDate)) ||
      !Number.isInteger(p.totalHours) || p.totalHours <= 0 ||
      p.usage?.usageGrain !== "Hourly" || p.usage.charges?.length !== p.totalHours ||
      !Array.isArray(p.allRecommendationDetails?.value) || !p.recommendationDetails) {
    throw new Error("Azure returned an incomplete savings-plan recommendation or scenario list.");
  }
  const baseline = number(p.costWithoutBenefit, "cost without new benefit");
  function point(detail) {
    const result = {
      commitment: number(detail.commitmentAmount, "hourly commitment"),
      benefitCost: number(detail.benefitCost, "benefit cost"),
      overageCost: number(detail.overageCost, "on-demand cost"),
      totalCost: number(detail.totalCost, "total cost"),
      savings: number(detail.savingsAmount, "savings", -Infinity),
      unusedCost: number(detail.wastageCost, "unused commitment"),
      coverage: percent(detail.coveragePercentage, "coverage"),
      utilization: percent(detail.averageUtilizationPercentage, "utilization"),
      savingsPercentage: number(detail.savingsPercentage, "savings percentage", -Infinity),
    };
    if (Math.abs(result.totalCost - result.benefitCost - result.overageCost) > 0.02 ||
        Math.abs(baseline - result.totalCost - result.savings) > 0.02 ||
        Math.abs(result.commitment * p.totalHours - result.benefitCost) > 0.02 ||
        result.unusedCost > result.benefitCost + 0.02) {
      throw new Error("Azure recommendation costs do not reconcile; modeling is unavailable.");
    }
    return result;
  }
  const recommended = point(p.recommendationDetails);
  const points = p.allRecommendationDetails.value.map(point);
  if (!points.some((value) => value.commitment === recommended.commitment)) points.push(recommended);
  points.sort((left, right) => left.commitment - right.commitment);
  if (new Set(points.map((value) => value.commitment)).size !== points.length) {
    throw new Error("Azure returned duplicate commitment options.");
  }
  const recommendedIndex = points.findIndex((value) => value.commitment === recommended.commitment);
  if (Math.abs(points[recommendedIndex].totalCost - recommended.totalCost) > 0.02) {
    throw new Error("Azure's highlighted recommendation conflicts with its scenario list.");
  }
  return {
    id: record.id, sku: p.armSkuName, term: p.term, currency: p.currencyCode,
    lookBackPeriod: p.lookBackPeriod, hours: p.totalHours, baseline,
    from: p.firstConsumptionDate, to: p.lastConsumptionDate, points, recommendedIndex,
  };
}

export function projectScenario(recommendation, index, hours = recommendation.hours) {
  if (!Number.isInteger(index) || index < 0 || index >= recommendation.points.length ||
      !Number.isFinite(hours) || hours <= 0) throw new Error("Select an available commitment scenario.");
  const point = recommendation.points[index];
  const factor = hours / recommendation.hours;
  return {
    commitment: point.commitment, coverage: point.coverage, utilization: point.utilization,
    baselineCost: recommendation.baseline * factor,
    totalCost: point.totalCost * factor, benefitCost: point.benefitCost * factor,
    onDemandCost: point.overageCost * factor, savings: point.savings * factor,
    unusedCost: point.unusedCost * factor, hours,
  };
}
