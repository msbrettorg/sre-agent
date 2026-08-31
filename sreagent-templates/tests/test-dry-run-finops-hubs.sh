#!/usr/bin/env bash
# tests/test-dry-run-finops-hubs.sh — finops-hubs: 4 backends × dry-run
set -uo pipefail
cd "$(dirname "$0")/.."
REPORT="/tmp/test-dry-run-finops-hubs.txt"; > "$REPORT"
source tests/lib/test-helpers.sh

RECIPE="finops-hubs"
EXTRA_SETS="finopsHubClusterUri=https://example.westus.kusto.windows.net/Hub"
EXP_SKILLS=1 EXP_SA=5 EXP_HOOKS=0 EXP_PROMPTS=1 EXP_SCHED=19 EXP_FILTERS=0 EXP_PLAT=0 EXP_HT=0
OUT="/tmp/dryrun-${RECIPE}"

log "═══ $RECIPE ═══"
log "── bash new-agent ──"
rm -rf "$OUT"
./bin/new-agent.sh --recipe "$RECIPE" --non-interactive \
  --set agentName="dry-${RECIPE}" \
  --set resourceGroup=rg-dry \
  --set location=swedencentral \
  --set targetRGs=rg-fake \
  --set finopsHubClusterUri=https://example.westus.kusto.windows.net/Hub \
  -o "$OUT" > /tmp/dryrun-new.log 2>&1
if [[ -f "$OUT/agent.json" ]]; then pass "new-agent"; else fail "new-agent"; print_summary "$RECIPE"; exit 1; fi
# User-authored report images are not deployment inputs and can contain binary
# byte sequences that resemble template placeholders.
rm -rf "$OUT/live-reports"

validate_config_dir "$OUT" $EXP_SKILLS $EXP_SA $EXP_HOOKS $EXP_PROMPTS $EXP_SCHED $EXP_FILTERS $EXP_PLAT $EXP_HT
validate_assembled_content "$OUT"

ASSEMBLED="$(mktemp -d)/assembled"
bash bicep/assemble-agent.sh "$OUT" --output "$ASSEMBLED" > /tmp/dryrun-finops-assemble.log 2>&1
PARAMETERS="${ASSEMBLED}.parameters.json"
EXTRAS="${ASSEMBLED}.extras.json"
assert_eq "ARM MCP data source" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-resource-manager-mcp") | .properties.dataSource' "$PARAMETERS")" "https://mcp.management.azure.com"
assert_eq "ARM MCP endpoint" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-resource-manager-mcp") | .properties.extendedProperties.endpoint' "$PARAMETERS")" "https://mcp.management.azure.com"
assert_eq "ARM MCP auth type" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-resource-manager-mcp") | .properties.extendedProperties.authType' "$PARAMETERS")" "AzureARM"
assert_eq "ARM MCP token scope" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-resource-manager-mcp") | .properties.extendedProperties.armScope' "$PARAMETERS")" "https://mcp.management.azure.com/.default"
assert_eq "ARM MCP toolset header" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-resource-manager-mcp") | .properties.extendedProperties["x-mcp-toolset"]' "$PARAMETERS")" "CostManagement"
assert_eq "ARM MCP excludes nested headers" "$(jq '[.parameters.connectors.value[] | select(.name == "azure-resource-manager-mcp") | .properties.extendedProperties | has("headers")] | any' "$PARAMETERS")" "false"
assert_eq "ARM MCP system identity" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-resource-manager-mcp") | .properties.identity' "$PARAMETERS")" "system"
assert_eq "ARM MCP excludes OAuth and UAMI" "$(jq '[.parameters.connectors.value[] | select(.name == "azure-resource-manager-mcp") | (.properties.extendedProperties.authType != "OAuth" and (.properties.identity | startswith("/subscriptions/") | not))] | all' "$PARAMETERS")" "true"
if cmp -s \
  <(jq -S '.connectors[] | select(.name == "azure-resource-manager-mcp")' "$OUT/connectors.json") \
  <(jq -S '.connectors[] | select(.name == "azure-resource-manager-mcp")' "agents/${RECIPE}/connectors.json"); then
  pass "recipe and generated ARM MCP connectors equivalent"
else
  fail "recipe and generated ARM MCP connectors equivalent"
fi
assert_eq "FinOps plugin MCP type" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-mcp-server") | .properties.extendedProperties.type' "$PARAMETERS")" "stdio"
assert_eq "FinOps plugin MCP command" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-mcp-server") | .properties.extendedProperties.command' "$PARAMETERS")" "npx"
assert_eq "FinOps plugin MCP arguments" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-mcp-server") | .properties.extendedProperties.args | join(" ")' "$PARAMETERS")" "-y @azure/mcp@latest server start --namespace kusto --read-only"
assert_eq "FinOps plugin MCP system identity" "$(jq -r '.parameters.connectors.value[] | select(.name == "azure-mcp-server") | .properties.identity' "$PARAMETERS")" "system"
assert_eq "FinOps plugin MCP wildcard tools" "$(jq '[.parameters.connectors.value[] | select(.name == "azure-mcp-server") | .properties.extendedProperties | .toolsVisibleToMetaAgent == ["*"] and .selectedTools == ["*"]] | all' "$PARAMETERS")" "true"
if cmp -s \
  <(jq -S '.connectors[] | select(.name == "azure-mcp-server")' "$OUT/connectors.json") \
  <(jq -S '.connectors[] | select(.name == "azure-mcp-server")' "agents/${RECIPE}/connectors.json"); then
  pass "recipe and generated FinOps plugin MCP connectors equivalent"
else
  fail "recipe and generated FinOps plugin MCP connectors equivalent"
fi
EXPECTED_ENABLED_TOOLS="KustoClient,PlotAreaChartWithCorrelation,PlotBarChart,PlotHeatmap,PlotPieChart,PlotScatter,QueryAppInsightsByAppId,QueryAppInsightsByResourceId,QueryLogAnalyticsByResourceId,QueryLogAnalyticsByWorkspaceId"
assert_eq "all Visualization and Log Query tools allowed" \
  "$(jq -r '[.toolPermissions.allow[] | select(. == "KustoClient" or startswith("Plot") or startswith("QueryAppInsights") or startswith("QueryLogAnalytics"))] | sort | join(",")' "$EXTRAS")" \
  "$EXPECTED_ENABLED_TOOLS"
assert_eq "global tool ask list empty" "$(jq '.toolPermissions.ask | length' "$EXTRAS")" "0"
assert_eq "global tool deny list empty" "$(jq '.toolPermissions.deny | length' "$EXTRAS")" "0"
assert_eq "all Visualization and Log Query tools enabled" \
  "$(jq -r '[.toolOverrides[] | select(.enabled == true) | .name] | sort | join(",")' "$EXTRAS")" \
  "$EXPECTED_ENABLED_TOOLS"
assert_eq "tool overrides contain only enabled entries" \
  "$(jq '[.toolOverrides[] | select(.enabled != true)] | length' "$EXTRAS")" \
  "0"
assert_eq "expected enabled tools" \
  "$(jq -r '.enabledTools | sort | join(",")' "$OUT/expected-config.json")" \
  "$EXPECTED_ENABLED_TOOLS"
if cmp -s \
  "recipes/${RECIPE}/tool-permissions.json" \
  "agents/${RECIPE}/tool-permissions.json" && \
  cmp -s \
  "recipes/${RECIPE}/tool-permissions.json" \
  "agents/finops-hub-sre/tool-permissions.json"; then
  pass "recipe and generated tool permissions equivalent"
else
  fail "recipe and generated tool permissions equivalent"
fi
if cmp -s \
  "recipes/${RECIPE}/tool-overrides.json" \
  "agents/${RECIPE}/tool-overrides.json" && \
  cmp -s \
  "recipes/${RECIPE}/tool-overrides.json" \
  "agents/finops-hub-sre/tool-overrides.json"; then
  pass "recipe and generated tool overrides equivalent"
else
  fail "recipe and generated tool overrides equivalent"
fi
if grep -Fq '/api/v2/agent/tools/configure' bicep/apply-extras.sh &&
   grep -Fq '/api/v2/agent/tools/configure' bicep/Apply-Extras.ps1; then
  pass "Bash and PowerShell apply built-in tool overrides"
else
  fail "Bash and PowerShell apply built-in tool overrides"
fi
if grep -Fq '/api/v2/agent/settings/global' bicep/apply-extras.sh &&
   grep -Fq '/api/v2/agent/settings/global' bicep/Apply-Extras.ps1; then
  pass "Bash and PowerShell apply built-in tool permissions"
else
  fail "Bash and PowerShell apply built-in tool permissions"
fi
assert_eq "assembled tools" "$(jq '.tools | length' "$EXTRAS")" "51"
assert_eq "zone-mapping present" "$(jq '[.tools[].metadata.name] | index("zone-mapping") != null' "$EXTRAS")" "true"
assert_eq "zone-mapping assigned" "$(jq '[.subagents[] | select(.metadata.name == "azure-capacity-manager") | .spec.tools[]] | index("zone-mapping") != null' "$EXTRAS")" "true"
assert_eq "assembled subagents" "$(jq '.subagents | length' "$EXTRAS")" "5"
assert_eq "assembled prompts" "$(jq '.commonPrompts | length' "$EXTRAS")" "1"
assert_eq "assembled local skills" "$(jq '.skills | length' "$EXTRAS")" "1"
assert_eq "cost skill references" "$(jq '[.skills[] | select(.metadata.name == "azure-cost-management") | .additionalFiles[]] | length' "$EXTRAS")" "13"
assert_eq "cost skill references resolved" "$(jq '[.skills[] | select(.metadata.name == "azure-cost-management") | .additionalFiles[].content] | all(length > 100 and (test("^(skills/|_file:)") | not))' "$EXTRAS")" "true"
assert_eq "marketplaces" "$(jq '.plugins.marketplaces | length' "$EXTRAS")" "2"
assert_eq "marketplace names" "$(jq -r '[.plugins.marketplaces[].name] | sort | join(",")' "$EXTRAS")" "azcapman,finops-toolkit"
assert_eq "marketplace installations" "$(jq '.plugins.installations | length' "$EXTRAS")" "2"
assert_eq "marketplace install operations" "$(jq '[.plugins.installations[] | select(.operation == "install-from-marketplace")] | length' "$EXTRAS")" "1"
assert_eq "direct install operations" "$(jq '[.plugins.installations[] | select(.operation == "install-direct")] | length' "$EXTRAS")" "1"
assert_eq "direct install path" "$(jq -r '.plugins.installations[] | select(.operation == "install-direct") | .spec.pathInRepo' "$EXTRAS")" "src/templates/agent-plugin"
assert_eq "direct install source ref" "$(jq -r '.plugins.installations[] | select(.operation == "install-direct") | .spec.sourceRef' "$EXTRAS")" "dev"
assert_eq "marketplace install skills" "$(jq -r '[.plugins.installations[].spec.expectedSkills[]] | sort | join(",")' "$EXTRAS")" "azure-capacity-management,finops-toolkit"
assert_eq "plugin auto-update disabled" "$(jq '[.plugins.installations[].spec.autoUpdate] | all(. == false)' "$EXTRAS")" "true"
assert_eq "no plugin credentials" "$(jq '[.plugins.marketplaces[].spec, .plugins.installations[].spec] | any(has("credentials"))' "$EXTRAS")" "false"
assert_eq "required local skills" "$(jq -r '.skills | sort | join(",")' "$OUT/expected-config.json")" "azure-cost-management"
assert_eq "required plugin skills" "$(jq -r '.pluginSkills | sort | join(",")' "$OUT/expected-config.json")" "azure-capacity-management,finops-toolkit"
assert_eq "additional skills allowed" "$(jq -r '.allowAdditionalSkills' "$OUT/expected-config.json")" "true"
assert_eq "additional connectors allowed" "$(jq -r '.allowAdditionalConnectors' "$OUT/expected-config.json")" "true"
assert_eq "additional repos allowed" "$(jq -r '.allowAdditionalRepos' "$OUT/expected-config.json")" "true"
assert_eq "no broad Agent Skills plugin" "$(grep -R -c 'MicrosoftDocs/Agent-Skills\\|azure-agent-skills' "$OUT/config/plugins" 2>/dev/null | awk -F: '{n += $NF} END {print n + 0}')" "0"
assert_eq "capacity tasks in Review" "$(jq '[.scheduledTasks[] | select(.metadata.name | IN("CapacityDailyMonitor", "CapacityWeeklySupplyReview", "CapacityMonthlyPlanning", "CapacityQuarterlyStrategy", "SkuAvailabilityAudit")) | select(.spec.mode == "Review")] | length' "$EXTRAS")" "5"
assert_eq "expected knowledge items" "$(jq '.knowledgeItems | length' "$EXTRAS")" "15"
if [[ "$(jq -r '.knowledgeItems[].name' "$EXTRAS" | sort)" == \
      "$(jq -r '.knowledgeItems[]' "$OUT/expected-config.json" | sort)" ]]; then
  pass "exact knowledge-item names"
else
  fail "exact knowledge-item names"
fi
assert_eq "no private review URL" "$(grep -R -c 'review.learn.microsoft.com\\|pr-en-us-3305' "$OUT" "$EXTRAS" 2>/dev/null | awk -F: '{n += $NF} END {print n + 0}')" "0"

validate_bicep_dryrun "$OUT"
validate_tf_dryrun "$OUT" 0 0 0
validate_ps_newagent "$RECIPE" "$EXTRA_SETS"
PS_OUT="/tmp/dryrun-ps-${RECIPE}"
PS_ASSEMBLED="$(mktemp -d)/assembled"
bash bicep/assemble-agent.sh "$PS_OUT" --output "$PS_ASSEMBLED" > /tmp/dryrun-finops-ps-assemble.log 2>&1
if cmp -s \
  <(jq -S 'del(._exported_from, .synthesizedKnowledgeDir)' "$EXTRAS") \
  <(jq -S 'del(._exported_from, .synthesizedKnowledgeDir)' "${PS_ASSEMBLED}.extras.json"); then
  pass "Bash and PowerShell extras equivalent"
else
  fail "Bash and PowerShell extras equivalent"
fi
if command -v pwsh >/dev/null 2>&1; then
  PS_NATIVE_ASSEMBLED="$(mktemp -d)/assembled"
  if pwsh -NoProfile -File bicep/Assemble-Agent.ps1 \
    -ConfigDir "$PS_OUT" \
    -Output "$PS_NATIVE_ASSEMBLED" >/tmp/dryrun-finops-native-ps-assemble.log 2>&1 &&
    cmp -s \
      <(jq -S '{toolPermissions, toolOverrides}' "$EXTRAS") \
      <(jq -S '{toolPermissions, toolOverrides}' "${PS_NATIVE_ASSEMBLED}.extras.json"); then
    pass "native PowerShell and Bash tool settings equivalent"
  else
    fail "native PowerShell and Bash tool settings equivalent (see /tmp/dryrun-finops-native-ps-assemble.log)"
  fi
fi
validate_azd_dryrun "$OUT"
if bash tests/test-plugin-marketplace-install.sh > /tmp/test-plugin-marketplace-install.log 2>&1; then
  pass "plugin marketplace lifecycle"
else
  fail "plugin marketplace lifecycle (see /tmp/test-plugin-marketplace-install.log)"
fi

print_summary "$RECIPE"
exit $?
