import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { setTimeout as delay } from "node:timers/promises";
import { normalizeRecommendation } from "./savings-plan-model.mjs";
import { coverageQuery, normalizeCoverage } from "./savings-plan-coverage.mjs";

const execFileAsync = promisify(execFile);
const host = "127.0.0.1";
const port = 4174;
const tenant = "91700184-c314-4dc9-bb7e-a411df456a1e";
const subscription = "8e9e64d9-d158-4638-a087-f2c60bff9e66";
const armOrigin = "https://management.azure.com";
const cluster = "https://ftk-sitecore-eus.eastus.kusto.windows.net";
const database = "Hub";
const kustoAudience = "https://api.kusto.windows.net";
const pagePath = new URL("./savings-plans.html", import.meta.url);
const allowedHosts = new Set([`${host}:${port}`, `localhost:${port}`]);
const allowedOrigins = new Set([...allowedHosts].map((value) => `http://${value}`));
const cachedTokens = new Map();
const pendingTokens = new Map();
let pendingSummary;

async function getToken(refresh = false, audience = `${armOrigin}/`) {
  const cached = cachedTokens.get(audience);
  if (!refresh && cached?.expiresAt > Date.now()) return cached.value;
  if (pendingTokens.has(audience)) return pendingTokens.get(audience);
  const pending = (async () => {
    const { stdout } = await execFileAsync("rtk", [
      "proxy", "az", "account", "get-access-token", "--tenant", tenant,
      "--resource", audience, "--query", "accessToken", "--output", "tsv",
    ]);
    const value = stdout.trim();
    if (!value) throw new Error("Azure CLI returned an empty access token.");
    cachedTokens.set(audience, { value, expiresAt: Date.now() + 5 * 60 * 1000 });
    return value;
  })();
  pendingTokens.set(audience, pending);
  try {
    return await pending;
  } finally {
    pendingTokens.delete(audience);
  }
}

async function readAzure(url, refresh = false, retried = false) {
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${await getToken(refresh)}` },
    signal: AbortSignal.timeout(30000),
    redirect: "error",
  });
  if (response.status === 401 && !refresh) return readAzure(url, true, retried);
  const text = await response.text();
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    throw new Error(`Azure returned HTTP ${response.status} with a non-JSON response.`);
  }
  if (!response.ok) {
    const retryAfter = response.headers.get("x-ms-ratelimit-microsoft.consumption-retry-after") ||
      response.headers.get("Retry-After");
    const seconds = retryAfter === null ? NaN : Number(retryAfter);
    if ([429, 503].includes(response.status) && !retried && Number.isFinite(seconds) &&
        seconds >= 0 && seconds <= 120) {
      console.warn(`[savings-plans] Azure HTTP ${response.status}; retrying once after ${seconds}s.`);
      await delay(seconds * 1000);
      return readAzure(url, refresh, true);
    }
    const error = new Error(`Azure HTTP ${response.status}: ${payload.error?.message || response.statusText}`);
    error.status = response.status;
    throw error;
  }
  return payload;
}

async function readList(endpoint, initialPage) {
  const records = [];
  const seen = new Set();
  let next = endpoint;
  let initial = initialPage;
  while (next) {
    if (next.origin !== armOrigin || next.pathname.toLowerCase() !== endpoint.pathname.toLowerCase() ||
        next.username || next.password || next.hash || seen.has(next.href) || seen.size >= 100) {
      throw new Error("Azure returned an invalid or repeated pagination link.");
    }
    seen.add(next.href);
    const page = initial || await readAzure(next);
    initial = null;
    if (!Array.isArray(page.value)) throw new Error("Azure did not return a result list.");
    records.push(...page.value);
    next = page.nextLink ? new URL(page.nextLink, armOrigin) : null;
  }
  return records;
}

async function readKusto(query, refresh = false) {
  const response = await fetch(`${cluster}/v1/rest/query`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${await getToken(refresh, kustoAudience)}`,
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ db: database, csl: query }),
    signal: AbortSignal.timeout(120000),
    redirect: "error",
  });
  if (response.status === 401 && !refresh) return readKusto(query, true);
  const payload = await response.json();
  if (!response.ok) {
    const error = new Error(`Kusto HTTP ${response.status}: ${payload.error?.["@message"] || payload.error?.message || response.statusText}`);
    error.status = response.status;
    throw error;
  }
  if (!Array.isArray(payload.Tables) || payload.Exceptions?.length) {
    throw new Error("Kusto returned an incomplete or partially failed coverage query.");
  }
  const statusTable = payload.Tables.find((table) =>
    table.Columns?.some((column) => column.ColumnName === "SeverityName"));
  if (statusTable) {
    const severity = statusTable.Columns.findIndex((column) => column.ColumnName === "Severity");
    const description = statusTable.Columns.findIndex((column) => column.ColumnName === "StatusDescription");
    const failure = statusTable.Rows.find((row) => row[severity] < 4);
    if (failure) throw new Error(`Kusto coverage query failed: ${failure[description]}`);
  }
  const table = payload.Tables.find((value) => value.TableName === "PrimaryResult") || payload.Tables[0];
  if (!Array.isArray(table?.Columns) || !Array.isArray(table?.Rows)) {
    throw new Error("Kusto did not return a coverage result table.");
  }
  const columns = table.Columns.map((column) => column.ColumnName);
  return table.Rows.map((row) => {
    if (!Array.isArray(row) || row.length !== columns.length) throw new Error("Kusto returned an incomplete coverage row.");
    return Object.fromEntries(columns.map((column, index) => [column, row[index]]));
  });
}

async function capture(source, operation) {
  try {
    return { source, status: "ready", data: await operation() };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[savings-plans] ${source}: ${message}`);
    return { source, status: "unavailable", error: { message, httpStatus: error.status || null } };
  }
}

async function recommendations(profileId, term) {
  const endpoint = new URL(`${profileId}/providers/Microsoft.CostManagement/benefitRecommendations`, armOrigin);
  endpoint.searchParams.set("api-version", "2025-03-01");
  endpoint.searchParams.set("$filter", `properties/lookBackPeriod eq 'Last30Days' AND properties/term eq '${term}' AND properties/scope eq 'Shared'`);
  endpoint.searchParams.set("$expand", "properties/usage,properties/allRecommendationDetails");
  const records = await readList(endpoint);
  const result = [];
  for (const record of records.filter((value) => value.kind === "SavingsPlan")) {
    if (record.properties?.allRecommendationDetails?.nextLink) {
      record.properties.allRecommendationDetails.value = await readList(
        endpoint, record.properties.allRecommendationDetails,
      );
    }
    const value = normalizeRecommendation(record);
    if (value.term !== term || value.lookBackPeriod !== "Last30Days") {
      throw new Error("Azure returned recommendations for a different term or look-back period.");
    }
    result.push(value);
  }
  if (new Set(result.map((value) => value.sku)).size !== result.length) {
    throw new Error("Azure returned overlapping recommendations for the same plan type and term.");
  }
  return result;
}

export function normalizePurchasedPlan(record, profileId) {
  const accountId = profileId.split("/billingProfiles/")[0];
  const prefix = `${accountId}/savingsPlanOrders/`;
  const p = record.properties;
  const parts = record.id?.slice(prefix.length).split("/");
  if (!record.id?.toLowerCase().startsWith(prefix.toLowerCase()) ||
      parts?.length !== 3 || parts[1].toLowerCase() !== "savingsplans" ||
      !/^[a-f0-9-]{36}$/i.test(parts[0]) || !/^[a-f0-9-]{36}$/i.test(parts[2]) ||
      p?.billingProfileId?.toLowerCase() !== profileId.toLowerCase() ||
      p?.billingAccountId?.toLowerCase() !== accountId.toLowerCase() ||
      !["Compute_Savings_Plan", "Database_Savings_Plan"].includes(record.sku?.name) ||
      !["P1Y", "P3Y"].includes(p.term) || p.commitment?.grain !== "Hourly" ||
      !Number.isFinite(p.commitment.amount) || p.commitment.amount < 0 ||
      !/^[A-Z]{3}$/.test(p.commitment.currencyCode) ||
      !Number.isFinite(Date.parse(p.expiryDateTime)) ||
      !Number.isFinite(Date.parse(p.benefitStartTime)) ||
      Date.parse(p.expiryDateTime) <= Date.parse(p.benefitStartTime) ||
      typeof p.provisioningState !== "string" || !p.displayName) {
    throw new Error("Azure Billing returned incomplete plan metadata or a different billing scope.");
  }
  return {
    id: `/providers/Microsoft.BillingBenefits/savingsPlanOrders/${parts[0]}/savingsPlans/${parts[2]}`,
    billingId: record.id, sku: record.sku.name, name: p.displayName,
    term: p.term, commitment: p.commitment.amount, currency: p.commitment.currencyCode,
    startsAt: p.benefitStartTime, expiresAt: p.expiryDateTime, state: p.provisioningState,
    appliedScope: p.appliedScopeType, source: "Azure Billing savingsPlans, 2024-04-01",
  };
}

async function purchasedPlans(profileId) {
  const accountId = profileId.split("/billingProfiles/")[0];
  const endpoint = new URL(`${accountId}/savingsPlans`, armOrigin);
  endpoint.searchParams.set("api-version", "2024-04-01");
  endpoint.searchParams.set("filter", `properties/billingProfileId eq '${profileId}'`);
  endpoint.searchParams.set("take", "100");
  const plans = (await readList(endpoint)).map((record) => normalizePurchasedPlan(record, profileId));
  if (new Set(plans.map((plan) => plan.id.toLowerCase())).size !== plans.length) {
    throw new Error("Azure Billing returned duplicate purchased plans.");
  }
  return plans;
}

export function reportingPeriod(now = new Date()) {
  const lastDay = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - 1));
  const firstDay = new Date(Date.UTC(lastDay.getUTCFullYear(), lastDay.getUTCMonth(), 1));
  return { from: firstDay.toISOString().slice(0, 10), to: lastDay.toISOString().slice(0, 10) };
}

function percentage(value, field) {
  if (!Number.isFinite(value) || value < -0.000001 || value > 100.000001) {
    throw new Error(`Azure returned an invalid ${field}; utilization was not substituted.`);
  }
  return Math.min(100, Math.max(0, value));
}

export function summarizePlans(records, period) {
  const plans = new Map();
  for (const record of records) {
    if (record.kind !== "SavingsPlan") continue;
    const properties = record.properties;
    if (!properties || typeof properties.benefitId !== "string" ||
        !/^\/providers\/Microsoft\.BillingBenefits\/savingsPlanOrders\/[^/]+\/savingsPlans\/[^/]+$/i.test(properties.benefitId) ||
        typeof properties.armSkuName !== "string" || !properties.armSkuName ||
        typeof properties.usageDate !== "string" || !Number.isFinite(Date.parse(properties.usageDate))) {
      throw new Error("Azure returned an incomplete savings-plan utilization record.");
    }
    const day = new Date(properties.usageDate).toISOString().slice(0, 10);
    if (day < period.from || day > period.to) continue;
    const average = percentage(properties.avgUtilizationPercentage, "average utilization");
    const minimum = percentage(properties.minUtilizationPercentage, "minimum utilization");
    const maximum = percentage(properties.maxUtilizationPercentage, "maximum utilization");
    if (minimum > average + 0.000001 || average > maximum + 0.000001) {
      throw new Error("Azure returned an inconsistent savings-plan utilization range.");
    }
    const id = properties.benefitId;
    const plan = plans.get(id) || { id, sku: properties.armSkuName, days: new Set(), latest: null };
    if (plan.days.has(day)) throw new Error(`Azure returned duplicate utilization for ${id} on ${day}.`);
    plan.days.add(day);
    if (!plan.latest || day > plan.latest.day) plan.latest = { day, average, minimum, maximum };
    plans.set(id, plan);
  }
  return [...plans.values()]
    .map((plan) => ({ id: plan.id, sku: plan.sku, reportedDays: plan.days.size, ...plan.latest }))
    .sort((left, right) => left.average - right.average || left.id.localeCompare(right.id));
}

async function loadSummary() {
  const billing = await readAzure(new URL(
    `/subscriptions/${subscription}/providers/Microsoft.Billing/billingProperty/default?api-version=2024-04-01`,
    armOrigin,
  ));
  const properties = billing.properties;
  const profileId = properties?.billingProfileId;
  if (typeof profileId !== "string" ||
      !/^\/providers\/Microsoft\.Billing\/billingAccounts\/[^/]+\/billingProfiles\/[^/]+$/i.test(profileId)) {
    throw new Error("The specified subscription did not return an MCA billing-profile scope.");
  }
  const period = reportingPeriod();
  const endpoint = new URL(`${profileId}/providers/Microsoft.CostManagement/benefitUtilizationSummaries`, armOrigin);
  endpoint.searchParams.set("api-version", "2025-03-01");
  endpoint.searchParams.set("grainParameter", "Daily");
  endpoint.searchParams.set("filter", `properties/usageDate ge ${period.from} and properties/usageDate le ${period.to}`);
  const inventoryPromise = capture("Purchased plan inventory", () => purchasedPlans(profileId));
  const [utilization, inventory, currentCoverage, ...recommendationSources] = await Promise.all([
    capture("Plan utilization", async () => summarizePlans(await readList(endpoint), period)),
    inventoryPromise,
    capture("Observed current coverage", async () => {
      const [rows, source] = await Promise.all([readKusto(coverageQuery(profileId, period)), inventoryPromise]);
      if (source.status !== "ready") throw new Error(`Plan inventory is required to verify applied benefits: ${source.error.message}`);
      return normalizeCoverage(rows, period, source.data);
    }),
    ...["P1Y", "P3Y"].map((term) => capture(`${term} recommendations`, () => recommendations(profileId, term))),
  ]);
  const now = Date.now();
  const plans = inventory.status === "ready" ? inventory.data
    .filter((plan) => plan.state === "Succeeded" && Date.parse(plan.startsAt) <= now && Date.parse(plan.expiresAt) > now)
    .map((plan) => {
      const usage = utilization.status === "ready" ? utilization.data.find((value) => value.id.toLowerCase() === plan.id.toLowerCase()) : null;
      if (usage && usage.sku !== plan.sku) throw new Error("Purchased plan type conflicts with utilization.");
      return {
        ...plan, reportedDays: usage?.reportedDays || 0, day: usage?.day || null,
        average: usage?.average ?? null, minimum: usage?.minimum ?? null, maximum: usage?.maximum ?? null,
      };
    }).sort((a, b) => (a.average ?? Infinity) - (b.average ?? Infinity) || a.id.localeCompare(b.id)) : null;
  const planDetails = (plans || []).map((plan) => ({ source: plan.id, status: "ready", data: plan }));
  return {
    source: "Azure Billing + Cost Management + FinOps Hub",
    transport: "Azure CLI + documented ARM and Kusto REST APIs",
    refreshedAt: new Date().toISOString(),
    period,
    scope: {
      tenant, subscription, billingProfileId: profileId,
      accountName: properties.billingAccountDisplayName || null,
      profileName: properties.billingProfileDisplayName || profileId.split("/").at(-1),
    },
    plans, inventory, utilization, planDetails, recommendationSources, currentCoverage,
    kusto: { cluster, database, toolName: "system-mcp-kusto_kusto_query" },
  };
}

function send(response, status, body, type = "application/json; charset=utf-8") {
  const content = typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  response.writeHead(status, {
    "Content-Type": type,
    "Content-Length": Buffer.byteLength(content),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  response.end(content);
}

const server = createServer(async (request, response) => {
  const address = request.socket.remoteAddress;
  if (!["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(address) ||
      !allowedHosts.has(request.headers.host) ||
      (request.headers.origin && !allowedOrigins.has(request.headers.origin))) {
    return send(response, 403, { error: "This dashboard accepts loopback, same-origin requests only." });
  }
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return send(response, 405, { error: "Only read-only GET requests are supported." });
  }
  try {
    const url = new URL(request.url, `http://${host}:${port}`);
    if (url.pathname === "/api/health") {
      return send(response, 200, { source: "live", tenant, subscription, scope: "linked billing profile" });
    }
    if (url.pathname === "/api/savings-plans" && !url.search) {
      if (!pendingSummary) pendingSummary = loadSummary().finally(() => { pendingSummary = null; });
      return send(response, 200, await pendingSummary);
    }
    if (url.pathname === "/" || url.pathname === "/savings-plans.html") {
      return send(response, 200, await readFile(pagePath), "text/html; charset=utf-8");
    }
    if (url.pathname === "/savings-plan-model.mjs") {
      return send(response, 200, await readFile(new URL("./savings-plan-model.mjs", import.meta.url)), "text/javascript; charset=utf-8");
    }
    if (url.pathname === "/favicon.ico") {
      response.writeHead(204);
      return response.end();
    }
    return send(response, 404, { error: "Not found." });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[savings-plans] ${message}`);
    return send(response, 502, { error: message });
  }
});

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  server.listen(port, host, () => {
    console.log(`Savings plans: http://${host}:${port}/`);
    console.log(`Subscription: ${subscription}; tenant: ${tenant}`);
  });
}
