#!/usr/bin/env bash
# tests/test-dry-run-cost-management.sh — cost-management recipe dry-run
set -uo pipefail
cd "$(dirname "$0")/.."
REPORT=/dev/null
source tests/lib/test-helpers.sh

RECIPE="cost-management"
EXTRA_SETS="existingUamiId=;existingAgentAppInsightsId="
EXP_SKILLS=1 EXP_SA=3 EXP_HOOKS=0 EXP_PROMPTS=1 EXP_SCHED=17 EXP_FILTERS=0 EXP_PLAT=0 EXP_HT=0
OUT="tests/.dryrun-${RECIPE}-$$"
if ! mkdir "$OUT"; then
  echo "Could not create test output directory: $OUT" >&2
  exit 1
fi
trap 'rm -rf "$OUT"' EXIT

log "═══ $RECIPE ═══"
log "── bash new-agent ──"
if ./bin/new-agent.sh --recipe "$RECIPE" --subscription ci-subscription --non-interactive --no-telemetry \
    --set agentName=dry-cost-management --set resourceGroup=rg-dry \
    --set location=swedencentral --set targetRGs=rg-fake \
    --set existingUamiId= --set 'modelProvider=Azure OpenAI' --set existingAgentAppInsightsId= \
    -o "$OUT/agent" >/dev/null 2>&1 && [[ -f "$OUT/agent/agent.json" ]]; then
  pass "new-agent"
else
  fail "new-agent"
  print_summary "$RECIPE"
  exit 1
fi

validate_config_dir "$OUT/agent" "$EXP_SKILLS" "$EXP_SA" "$EXP_HOOKS" "$EXP_PROMPTS" \
  "$EXP_SCHED" "$EXP_FILTERS" "$EXP_PLAT" "$EXP_HT"
validate_bicep_dryrun "$OUT/agent"
SRE_AGENT_NO_TELEMETRY=1 validate_ps_newagent "$RECIPE" "$EXTRA_SETS"
PS_OUT="/tmp/dryrun-ps-${RECIPE}"
if [[ -f "$PS_OUT/agent.json" ]]; then
  validate_config_dir "$PS_OUT" "$EXP_SKILLS" "$EXP_SA" "$EXP_HOOKS" "$EXP_PROMPTS" \
    "$EXP_SCHED" "$EXP_FILTERS" "$EXP_PLAT" "$EXP_HT"
fi

log "── validate assembled content ──"
if bash bicep/assemble-agent.sh "$OUT/agent" --output "$OUT/assembled" >/dev/null 2>&1; then
  pass "assemble"
else
  fail "assemble"
  print_summary "$RECIPE"
  exit 1
fi

EXTRAS="$OUT/assembled.extras.json"
for ((i=0; i<EXP_SKILLS; i++)); do
  sname=$(jq -r --argjson i "$i" '.skills[$i].metadata.name' "$EXTRAS")
  sclen=$(jq -r --argjson i "$i" '.skills[$i].skillContent | length' "$EXTRAS")
  assert_gt "skill $sname content" "$sclen" 50
done
for ((i=0; i<EXP_SA; i++)); do
  saname=$(jq -r --argjson i "$i" '.subagents[$i].metadata.name' "$EXTRAS")
  salen=$(jq -r --argjson i "$i" '.subagents[$i].spec.instructions | length' "$EXTRAS")
  assert_gt "subagent $saname instructions" "$salen" 50
done
assert_nonempty "custom instructions" "$(jq -r '.customInstructions // empty' "$EXTRAS")"
assert_eq "custom tools" "$(jq '.tools | length' "$EXTRAS")" 13
assert_eq "microsoft-teams connector operations" \
  "$(jq '[.connectorV2[]? | select(.metadata.name == "microsoft-teams") | .spec.operations | length] | if length == 1 then .[0] else null end' "$EXTRAS")" 7

log "── validate Linux MAX_ARG_STRLEN (131,071 bytes) safety ──"
MOCK_BIN="$OUT/mock-bin"
mkdir -p "$MOCK_BIN" "$OUT/captured"
ARG_VIOLATIONS="$OUT/arg-violations.log"
: > "$ARG_VIOLATIONS"
REAL_JQ="$(command -v jq)"
REAL_CURL="$(command -v curl)"
REAL_PYTHON3="$(command -v python3)"

cat > "$MOCK_BIN/check-args.sh" <<'EOF'
#!/usr/bin/env bash
LC_ALL=C
tool_name="$1"
shift
prev=""
for arg in "$@"; do
  if (( ${#arg} >= 131072 )); then
    printf '%s arg after %s is %d bytes (limit 131071)\n' "$tool_name" "$prev" "${#arg}" >> "$ARG_VIOLATIONS"
    exit 126
  fi
  prev="$arg"
done
while IFS= read -r -d '' env_entry; do
  if (( ${#env_entry} >= 131072 )); then
    printf '%s env entry %s is %d bytes (limit 131071)\n' "$tool_name" "${env_entry%%=*}" "${#env_entry}" >> "$ARG_VIOLATIONS"
    exit 126
  fi
done < <(env -0)
EOF
chmod +x "$MOCK_BIN/check-args.sh"

cat > "$MOCK_BIN/jq" <<EOF
#!/usr/bin/env bash
"$MOCK_BIN/check-args.sh" jq "\$@" || exit \$?
exec "$REAL_JQ" "\$@"
EOF

cat > "$MOCK_BIN/python3" <<EOF
#!/usr/bin/env bash
"$MOCK_BIN/check-args.sh" python3 "\$@" || exit \$?
exec "$REAL_PYTHON3" "\$@"
EOF

cat > "$MOCK_BIN/az" <<'EOF'
#!/usr/bin/env bash
"$MOCK_BIN_DIR/check-args.sh" az "$@" || exit $?
if [[ "$1" == "rest" ]]; then
  printf '%s\n' '{"properties":{"agentEndpoint":"https://agent.test","actionConfiguration":{"accessLevel":"Low","mode":"Review"},"upgradeChannel":"Preview","defaultModel":{"provider":"Anthropic"}},"identity":{"userAssignedIdentities":{}}}'
elif [[ "$1" == "account" && "$2" == "get-access-token" ]]; then
  printf '%s\n' 'test-token'
else
  printf '%s\n' '{}'
fi
EOF

cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
"$MOCK_BIN_DIR/check-args.sh" curl "$@" || exit $?
url=''
body=''
body_file=''
headers_out=false
write_code=false
method='GET'
while [[ $# -gt 0 ]]; do
  case "$1" in
    http*) url="$1" ;;
    -X|--request) shift; method="$1" ;;
    -D-) headers_out=true ;;
    -w) shift; [[ "$1" == *"%{http_code}"* ]] && write_code=true ;;
    --data|-d|--data-binary)
      shift
      if [[ "$1" == @- ]]; then
        body="$(cat)"
      elif [[ "$1" == @* ]]; then
        body_file="${1#@}"
      else
        body="$1"
      fi
      ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >> "$CAPTURED_DIR/calls.log"
if [[ "$url" == */extendedAgent/skills/azure-cost-management && "$method" == "PUT" ]]; then
  if [[ -n "$body_file" ]]; then
    cp "$body_file" "$CAPTURED_DIR/skill-body.json"
  else
    printf '%s' "$body" > "$CAPTURED_DIR/skill-body.json"
  fi
fi
if [[ "$url" == */agent/customInstructions && "$method" == "GET" ]]; then
  cat "$CAPTURED_DIR/custom-instructions-response.json"
  exit 0
fi
if [[ "$headers_out" == true ]]; then
  printf 'HTTP/1.1 200 OK\r\nETag: "1"\r\n\r\n'
  exit 0
fi
if [[ "$url" == */connectorV2/connections/* && "$url" != */accessPolicies/* ]]; then
  resp='{"properties":{"overallStatus":"Connected"}}'
else
  resp='{}'
fi
if [[ "$write_code" == true ]]; then
  printf '%s\n200\n' "$resp"
else
  printf '%s\n' "$resp"
fi
EOF

cat > "$MOCK_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN/jq" "$MOCK_BIN/python3" "$MOCK_BIN/az" "$MOCK_BIN/curl" "$MOCK_BIN/sleep"

if ARG_VIOLATIONS="$ARG_VIOLATIONS" MOCK_BIN_DIR="$MOCK_BIN" CAPTURED_DIR="$OUT/captured" \
    PATH="$MOCK_BIN:$PATH" bash bicep/assemble-agent.sh "$OUT/agent" --output "$OUT/linux-assembled" >/dev/null 2>&1; then
  pass "Linux MAX_ARG_STRLEN assemble-agent.sh"
else
  fail "Linux MAX_ARG_STRLEN assemble-agent.sh"
fi

APPLY_LOG="$OUT/apply-extras.log"
if ARG_VIOLATIONS="$ARG_VIOLATIONS" MOCK_BIN_DIR="$MOCK_BIN" CAPTURED_DIR="$OUT/captured" \
    PATH="$MOCK_BIN:$PATH" bash bicep/apply-extras.sh \
    test-sub test-rg dry-cost-management "$OUT/linux-assembled.extras.json" >"$APPLY_LOG" 2>&1; then
  pass "Linux MAX_ARG_STRLEN apply-extras.sh"
else
  fail "Linux MAX_ARG_STRLEN apply-extras.sh"
fi

if [[ ! -s "$ARG_VIOLATIONS" ]]; then
  pass "zero oversized CLI args or env vars"
else
  fail "oversized CLI args or env vars: $(tr '\n' '; ' < "$ARG_VIOLATIONS")"
fi

if ! grep -Eq 'FAILED|skipped' "$APPLY_LOG"; then
  pass "apply-extras logged zero failures or skips"
else
  fail "apply-extras logged failures or skips"
fi

if [[ -f "$OUT/captured/skill-body.json" ]]; then
  assert_eq "uploaded skill additionalFiles count" \
    "$("$REAL_JQ" '.properties.additionalFiles | length' "$OUT/captured/skill-body.json")" 12
  assert_gt "uploaded skill content length" \
    "$("$REAL_JQ" '.properties.skillContent | length' "$OUT/captured/skill-body.json")" 5000
else
  fail "apply-extras did not PUT skills/azure-cost-management"
fi

# Verify >131 KB customInstructions also passes verify-agent.sh under MAX_ARG_STRLEN
LARGE_DIR="$OUT/large-verify"
mkdir -p "$LARGE_DIR"
"$REAL_PYTHON3" -c '
import json, sys
big = "Rule: keep FinOps checks deterministic.\n" * 3600
with open(sys.argv[1], "w") as f:
    json.dump({"customInstructions": big}, f)
with open(sys.argv[2], "w") as f:
    json.dump({"instructions": big}, f)
' "$LARGE_DIR/expected-config.json" "$OUT/captured/custom-instructions-response.json"

VERIFY_LOG="$OUT/verify-large.log"
ARG_VIOLATIONS="$ARG_VIOLATIONS" MOCK_BIN_DIR="$MOCK_BIN" CAPTURED_DIR="$OUT/captured" \
  PATH="$MOCK_BIN:$PATH" bash bin/verify-agent.sh test-sub test-rg dry-cost-management --expected "$LARGE_DIR" >"$VERIFY_LOG" 2>&1 || true
if [[ ! -s "$ARG_VIOLATIONS" ]] && grep -q 'Custom instructions.*match' "$VERIFY_LOG"; then
  pass "Linux MAX_ARG_STRLEN verify-agent.sh large customInstructions"
else
  fail "Linux MAX_ARG_STRLEN verify-agent.sh large customInstructions"
fi

log "── validate PowerShell assembled content ──"
if pwsh -NoProfile -File bicep/Assemble-Agent.ps1 -ConfigDir "$PS_OUT" -Output "$OUT/assembled-ps" >/dev/null 2>&1; then
  pass "PS assemble"
  PS_EXTRAS="$OUT/assembled-ps.extras.json"
  assert_nonempty "PS custom instructions" "$(jq -r '.customInstructions // empty' "$PS_EXTRAS")"
  assert_eq "PS custom tools" "$(jq '.tools | length' "$PS_EXTRAS")" 13
  assert_eq "PS microsoft-teams connector operations" \
    "$(jq '[.connectorV2[]? | select(.metadata.name == "microsoft-teams") | .spec.operations | length] | if length == 1 then .[0] else null end' "$PS_EXTRAS")" 7
else
  fail "PS assemble"
fi

print_summary "$RECIPE"
