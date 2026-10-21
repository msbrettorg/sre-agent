import { randomBytes } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const reports = [
  {
    source: join(root, "FinOps-Hub-MTD-KPI-Cockpit.html"),
    output: join(root, "FinOps-Hub-MTD-KPI-Cockpit.local.html"),
  },
  {
    source: join(root, "FinOps-Hub-Savings-Plans.html"),
    output: join(root, "FinOps-Hub-Savings-Plans.local.html"),
  },
];
const bridgePath = join(root, "live-sreagent.js");
const clusterPlaceholder = "REPLACE_WITH_FINOPS_HUB_CLUSTER_URI";
const applicationScriptMarker =
  `  <script nonce="{REPORT_NONCE}">\n` +
  `    const TOOL_NAME = 'system-mcp-kusto_kusto_query';`;

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

function replaceOnce(source, marker, replacement, description) {
  const first = source.indexOf(marker);
  if (first === -1 || source.indexOf(marker, first + marker.length) !== -1) {
    throw new Error(`Expected exactly one ${description}.`);
  }
  return source.slice(0, first) + replacement + source.slice(first + marker.length);
}

const clusterUri = normalizeClusterUri(process.env.KUSTO_CLUSTER_URI);
const database = process.env.KUSTO_DATABASE || "Hub";
if (!/^[A-Za-z0-9_.-]+$/.test(database)) {
  throw new Error("KUSTO_DATABASE contains unsupported characters.");
}

const bridgeScript = await readFile(bridgePath, "utf8");
if (bridgeScript.includes("</script>")) {
  throw new Error("The local bridge contains an unsafe closing script tag.");
}

for (const report of reports) {
  const rawSourceHtml = await readFile(report.source, "utf8");
  const sourceHtml = rawSourceHtml.replaceAll("\r\n", "\n");

  let localHtml = replaceOnce(
    sourceHtml,
    clusterPlaceholder,
    clusterUri,
    `cluster placeholder in ${report.source}`,
  );
  localHtml = replaceOnce(
    localHtml,
    "const DATABASE = 'Hub';",
    `const DATABASE = ${JSON.stringify(database)};`,
    `database constant in ${report.source}`,
  );
  localHtml = replaceOnce(
    localHtml,
    applicationScriptMarker,
    `<script nonce="{REPORT_NONCE}">\n${bridgeScript}\n</script>\n\n${applicationScriptMarker}`,
    `application script marker in ${report.source}`,
  );
  localHtml = localHtml.replaceAll(
    "{REPORT_NONCE}",
    randomBytes(18).toString("base64"),
  );

  await writeFile(report.output, localHtml);
  console.log(`Generated ${report.output}`);
}
