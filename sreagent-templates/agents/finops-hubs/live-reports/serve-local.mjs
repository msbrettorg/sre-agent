import { execFile } from "node:child_process";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const root = dirname(fileURLToPath(import.meta.url));
const cockpitReportPath = join(root, "FinOps-Hub-MTD-KPI-Cockpit.local.html");
const savingsPlansReportPath = join(root, "FinOps-Hub-Savings-Plans.local.html");
const reportRoutes = new Map([
  ["/", cockpitReportPath],
  ["/report.local.html", cockpitReportPath],
  ["/FinOps-Hub-MTD-KPI-Cockpit.local.html", cockpitReportPath],
  ["/savings-plans", savingsPlansReportPath],
  ["/savings-plans.local.html", savingsPlansReportPath],
  ["/FinOps-Hub-Savings-Plans.local.html", savingsPlansReportPath],
]);
const host = "127.0.0.1";
const port = Number.parseInt(process.env.PORT || "4174", 10);
const tenant = process.env.AZURE_TENANT_ID || "";
const clusterUri = normalizeClusterUri(process.env.KUSTO_CLUSTER_URI);
const database = process.env.KUSTO_DATABASE || "Hub";
const tokenResource = "https://api.kusto.windows.net";
const toolName = "system-mcp-kusto_kusto_query";
const maxRequestBytes = 2 * 1024 * 1024;
const allowedOrigins = new Set([
  `http://${host}:${port}`,
  `http://localhost:${port}`,
]);

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error(`Invalid PORT value: ${process.env.PORT}`);
}
if (!/^[A-Za-z0-9_.-]+$/.test(database)) {
  throw new Error("KUSTO_DATABASE contains unsupported characters.");
}

let tokenCache = null;

function normalizeClusterUri(value) {
  if (!value) {
    throw new Error("KUSTO_CLUSTER_URI is required.");
  }

  const url = new URL(value);
  if (url.protocol !== "https:") {
    throw new Error("KUSTO_CLUSTER_URI must use HTTPS.");
  }
  if (url.pathname !== "/" || url.search || url.hash) {
    throw new Error(
      "KUSTO_CLUSTER_URI must be the cluster origin without a database path.",
    );
  }
  return url.origin;
}

function isLoopback(address) {
  return (
    address === "127.0.0.1" ||
    address === "::1" ||
    address === "::ffff:127.0.0.1"
  );
}

function sendJson(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body),
    "Content-Type": "application/json; charset=utf-8",
    "X-Content-Type-Options": "nosniff",
  });
  response.end(body);
}

function tokenExpiry(payload) {
  const epochSeconds = Number(payload.expires_on);
  if (Number.isFinite(epochSeconds) && epochSeconds > 0) {
    return epochSeconds * 1000;
  }

  const parsed = Date.parse(payload.expiresOn || "");
  return Number.isNaN(parsed) ? Date.now() + 5 * 60 * 1000 : parsed;
}

async function getAccessToken(forceRefresh = false) {
  if (
    !forceRefresh &&
    tokenCache &&
    tokenCache.expiresAt - 2 * 60 * 1000 > Date.now()
  ) {
    return tokenCache.value;
  }

  const args = [
    "account",
    "get-access-token",
    "--resource",
    tokenResource,
    "--output",
    "json",
  ];
  if (tenant) args.push("--tenant", tenant);

  const { stdout } = await execFileAsync("az", args, {
    maxBuffer: 4 * 1024 * 1024,
    timeout: 30_000,
  });
  const payload = JSON.parse(stdout);
  if (!payload.accessToken) {
    throw new Error("Azure CLI returned an empty Kusto access token.");
  }

  tokenCache = {
    value: payload.accessToken,
    expiresAt: tokenExpiry(payload),
  };
  return tokenCache.value;
}

function primaryTable(payload) {
  if (!payload || !Array.isArray(payload.Tables)) return null;
  return (
    payload.Tables.find((table) => table.TableKind === "PrimaryResult") ||
    payload.Tables.find((table) => table.TableName === "PrimaryResult") ||
    payload.Tables[0] ||
    null
  );
}

async function executeKusto(query, forceRefresh = false) {
  const token = await getAccessToken(forceRefresh);
  const result = await fetch(`${clusterUri}/v1/rest/query`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "X-MS-App": "FinOpsHubLiveReportLocal",
      "X-MS-Client-Request-Id": `FinOpsHubLiveReportLocal;${crypto.randomUUID()}`,
    },
    body: JSON.stringify({ db: database, csl: query }),
    signal: AbortSignal.timeout(60_000),
  });

  if (result.status === 401 && !forceRefresh) {
    tokenCache = null;
    return executeKusto(query, true);
  }

  const text = await result.text();
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    throw new Error(
      `Kusto returned HTTP ${result.status} with a non-JSON response.`,
    );
  }
  if (!result.ok) {
    const detail =
      payload?.error?.["@message"] ||
      payload?.error?.message ||
      payload?.message;
    throw new Error(detail || `Kusto query failed with HTTP ${result.status}.`);
  }

  const table = primaryTable(payload);
  if (!table) return { results: { items: [] } };

  const columnNames = table.Columns.map((column) => column.ColumnName);
  const header = Object.fromEntries(columnNames.map((name) => [name, null]));
  return { results: { items: [header, ...table.Rows] } };
}

async function readRequestBody(request) {
  const declaredLength = Number.parseInt(
    request.headers["content-length"] || "0",
    10,
  );
  if (declaredLength > maxRequestBytes) {
    throw new Error("Request exceeds the 2 MB bridge limit.");
  }

  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > maxRequestBytes) {
      throw new Error("Request exceeds the 2 MB bridge limit.");
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function handleQuery(request, response) {
  const origin = request.headers.origin;
  if (origin && !allowedOrigins.has(origin)) {
    return sendJson(response, 403, {
      error: `Origin is not allowed: ${origin}`,
    });
  }
  if (request.method !== "POST") {
    response.writeHead(405, { Allow: "POST" });
    return response.end();
  }

  let body;
  try {
    body = JSON.parse(await readRequestBody(request));
  } catch (error) {
    return sendJson(response, 400, {
      error: error instanceof Error ? error.message : "Invalid request body.",
    });
  }

  if (body?.name !== toolName) {
    return sendJson(response, 403, {
      error: `Tool is not allowed: ${String(body?.name || "")}`,
    });
  }

  const args = body.args;
  let requestedCluster;
  try {
    requestedCluster = normalizeClusterUri(args?.["cluster-uri"]);
  } catch {
    return sendJson(response, 400, {
      error: "A valid HTTPS cluster-uri is required.",
    });
  }
  if (requestedCluster !== clusterUri || args?.database !== database) {
    return sendJson(response, 403, {
      error: "The requested Kusto target is not allowed by this bridge.",
    });
  }
  if (typeof args?.query !== "string" || !args.query.trim()) {
    return sendJson(response, 400, {
      error: "A non-empty Kusto query is required.",
    });
  }
  if (args.query.trimStart().startsWith(".")) {
    return sendJson(response, 403, {
      error: "Kusto management commands are not allowed by this bridge.",
    });
  }

  try {
    return sendJson(response, 200, await executeKusto(args.query));
  } catch (error) {
    console.error(
      `[kusto] ${error instanceof Error ? error.message : String(error)}`,
    );
    return sendJson(response, 502, {
      error: error instanceof Error ? error.message : "Kusto query failed.",
    });
  }
}

async function handleReport(request, response, targetPath) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    response.writeHead(405, { Allow: "GET, HEAD" });
    return response.end();
  }

  try {
    const fileStat = await stat(targetPath);
    if (!fileStat.isFile()) throw new Error("Local report is not a file.");
    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Content-Length": fileStat.size,
      "Content-Type": "text/html; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    });
    if (request.method === "HEAD") return response.end();
    return createReadStream(targetPath).pipe(response);
  } catch {
    return sendJson(response, 404, {
      error: "Run node build-local.mjs before starting the local server.",
    });
  }
}

const server = createServer(async (request, response) => {
  if (!isLoopback(request.socket.remoteAddress)) {
    return sendJson(response, 403, {
      error: "The local bridge accepts loopback connections only.",
    });
  }

  const url = new URL(
    request.url || "/",
    `http://${request.headers.host || `${host}:${port}`}`,
  );
  if (url.pathname === "/api/health") {
    return sendJson(response, 200, {
      auth: "Azure CLI",
      clusterUri,
      database,
      dataSource: "live",
      tenant: tenant || "Azure CLI default",
      toolName,
    });
  }
  if (url.pathname === "/api/kusto/query") {
    return handleQuery(request, response);
  }
  if (reportRoutes.has(url.pathname)) {
    return handleReport(request, response, reportRoutes.get(url.pathname));
  }

  response.writeHead(404);
  return response.end();
});

server.listen(port, host, () => {
  console.log(`MTD KPI Cockpit: http://${host}:${port}/`);
  console.log(`Savings Plans:   http://${host}:${port}/savings-plans`);
  console.log(`Kusto target:    ${clusterUri}/${database}`);
  console.log(`Tenant:          ${tenant || "Azure CLI default"}`);
});
