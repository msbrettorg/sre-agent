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
EXTRAS="${ASSEMBLED}.extras.json"
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
validate_azd_dryrun "$OUT"
if bash tests/test-plugin-marketplace-install.sh > /tmp/test-plugin-marketplace-install.log 2>&1; then
  pass "plugin marketplace lifecycle"
else
  fail "plugin marketplace lifecycle (see /tmp/test-plugin-marketplace-install.log)"
fi

print_summary "$RECIPE"
exit $?
