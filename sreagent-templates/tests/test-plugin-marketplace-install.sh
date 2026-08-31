#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d /tmp/test-plugin-marketplace.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/extras.json" <<'JSON'
{
  "plugins": {
    "marketplaces": [
      {
        "name": "test-marketplace",
        "spec": {
          "sourceType": "github",
          "sourceUrl": "example/skills",
          "owner": { "name": "Example" }
        }
      }
    ],
    "installations": [
      {
        "name": "test-marketplace-test-skill",
        "operation": "install-from-marketplace",
        "spec": {
          "marketplaceName": "test-marketplace",
          "pluginName": "test-plugin",
          "expectedSkills": ["test-skill"],
          "autoUpdate": false
        }
      },
      {
        "name": "test-direct-skill",
        "operation": "install-direct",
        "spec": {
          "sourceUrl": "example/direct-skills",
          "sourceRef": "dev",
          "pathInRepo": "plugins/test-plugin",
          "pluginName": "test-direct-plugin",
          "expectedSkills": ["test-direct-skill"],
          "autoUpdate": false
        }
      }
    ]
  }
}
JSON

mkdir -p "$TMP/expected"
cat > "$TMP/expected/expected-config.json" <<'JSON'
{
  "agent": {
    "accessLevel": "Low",
    "actionMode": "Review",
    "upgradeChannel": "Preview",
    "defaultModelProvider": "MicrosoftFoundry",
    "incidentPlatform": "None"
  },
  "connectors": [],
  "skills": [
    "azure-capacity-management",
    "azure-cost-management",
    "finops-toolkit"
  ],
  "allowAdditionalSkills": true,
  "subagents": [],
  "hooks": [],
  "commonPrompts": [],
  "scheduledTasks": [],
  "responsePlans": [],
  "repos": []
}
JSON

cat > "$TMP/bin/az" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "rest" ]]; then
  if [[ "$*" == *"/DataConnectors?"* ]]; then
    printf '%s\n' '{"value":[]}'
  else
    printf '%s\n' '{"properties":{"agentEndpoint":"https://mock.agent","actionConfiguration":{"accessLevel":"Low","mode":"Review"},"upgradeChannel":"Preview","defaultModel":{"provider":"MicrosoftFoundry"},"incidentManagementConfiguration":null,"experimentalSettings":{}},"identity":{"userAssignedIdentities":{}}}'
  fi
elif [[ "${1:-}" == "account" && "${2:-}" == "get-access-token" ]]; then
  printf '%s\n' 'mock-token'
else
  printf 'unexpected az invocation: %s\n' "$*" >&2
  exit 1
fi
SH
chmod +x "$TMP/bin/az"

cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "ls-remote" ]]; then
  printf 'unexpected git invocation: %s\n' "$*" >&2
  exit 1
fi
default_ref=dev
[[ "${STUB_WRONG_DEFAULT:-0}" == "1" ]] && default_ref=main
printf 'ref: refs/heads/%s\tHEAD\n' "$default_ref"
printf 'fedcba9876543210fedcba9876543210fedcba98\tHEAD\n'
printf 'fedcba9876543210fedcba9876543210fedcba98\trefs/heads/dev\n'
SH
chmod +x "$TMP/bin/git"

cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
method=GET
url=
body=
write_status=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -w) write_status=true; shift 2 ;;
    --data) body="$2"; shift 2 ;;
    -H) shift 2 ;;
    -s|-S|-sS|-f) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\t%s\t%s\n' "$method" "$url" "$body" >> "$STUB_LOG"

case "$method $url" in
  "GET https://mock.agent/api/v2/plugins/marketplaces")
    if [[ -f "$STUB_STATE/marketplace" ]]; then
      response='{"value":[{"metadata":{"name":"test-marketplace"},"spec":{"sourceType":"github","sourceUrl":"example/skills","cloneError":"clone failed"}}]}'
    else
      response='{"value":[]}'
    fi
    ;;
  "POST https://mock.agent/api/v2/plugins/marketplaces")
    touch "$STUB_STATE/marketplace"
    response='{}'
    ;;
  "GET https://mock.agent/api/v2/plugins/marketplaces/test-marketplace/resolve")
    if [[ "${STUB_RESOLVE_FAIL:-0}" == "1" ]]; then
      response='{"success":false}'
    else
      response='{"success":true,"plugins":[{"name":"test-plugin"}]}'
    fi
    ;;
  "GET https://mock.agent/api/v2/plugins/marketplaces/test-marketplace/plugins/test-plugin/skills")
    if [[ "${STUB_UNEXPECTED_SKILL:-0}" == "1" ]]; then
      response='{"success":true,"skills":[{"name":"test-skill"},{"name":"extra-skill"}]}'
    else
      response='{"success":true,"skills":[{"name":"test-skill"}]}'
    fi
    ;;
  "GET https://mock.agent/api/v2/plugins/installations")
    response='{"value":['
    separator=
    if [[ -f "$STUB_STATE/installed" ]]; then
      response+='{"metadata":{"name":"installed"},"spec":{"marketplaceName":"test-marketplace","pluginName":"test-plugin","importedSkills":[{"skillName":"test-skill","sourceSkillName":"test-skill"}],"sourceCommit":"0123456789abcdef","autoUpdate":false}}'
      separator=,
    fi
    if [[ -f "$STUB_STATE/direct-installed" ]]; then
      direct_commit=fedcba9876543210fedcba9876543210fedcba98
      [[ -f "$STUB_STATE/direct-stale" ]] && direct_commit=0123456789abcdef0123456789abcdef01234567
      response+="${separator}{\"metadata\":{\"name\":\"direct-installed\"},\"spec\":{\"marketplaceName\":null,\"pluginName\":\"test-direct-plugin\",\"source\":{\"repo\":\"example/direct-skills\"},\"importedSkills\":[{\"skillName\":\"test-direct-skill\",\"sourceSkillName\":\"test-direct-skill\"}],\"sourceCommit\":\"${direct_commit}\",\"autoUpdate\":false}}"
    fi
    response+=']}'
    ;;
  "POST https://mock.agent/api/v2/plugins/marketplaces/test-marketplace/plugins/test-plugin/install")
    touch "$STUB_STATE/installed"
    response='{"success":true,"skillCount":1}'
    ;;
  "PUT https://mock.agent/api/v2/github/domains/github_com")
    response='{}'
    ;;
  "POST https://mock.agent/api/v2/plugins/install-direct")
    touch "$STUB_STATE/direct-installed"
    response='{"success":true,"skillCount":1}'
    ;;
  "DELETE https://mock.agent/api/v2/plugins/installations/direct-installed")
    rm -f "$STUB_STATE/direct-installed" "$STUB_STATE/direct-stale"
    response='{}'
    ;;
  "GET https://mock.agent/api/v1/extendedAgent/skills")
    if [[ "${STUB_MISSING_SKILL:-0}" == "1" ]]; then
      response='[{"name":"azure-capacity-management"},{"name":"azure-cost-management"},{"name":"impeccable"}]'
    else
      response='[{"name":"azure-capacity-management"},{"name":"azure-cost-management"},{"name":"finops-toolkit"},{"name":"impeccable"}]'
    fi
    ;;
  "GET https://mock.agent/api/v2/extendedAgent/agents"|"GET https://mock.agent/api/v2/extendedAgent/hooks"|"GET https://mock.agent/api/v2/extendedAgent/commonprompts"|"GET https://mock.agent/api/v2/repos")
    response='{"value":[]}'
    ;;
  "GET https://mock.agent/api/v1/scheduledtasks"|"GET https://mock.agent/api/v1/incidentPlayground/filters")
    response='[]'
    ;;
  "GET https://mock.agent/api/v1/Github/auth/status")
    response='{}'
    ;;
  *)
    printf 'unexpected curl invocation: %s %s\n' "$method" "$url" >&2
    exit 1
    ;;
esac

printf '%s' "$response"
if [[ "$write_status" == "true" ]]; then printf '\n200'; fi
SH
chmod +x "$TMP/bin/curl"

run_apply() {
  rm -f "$TMP/state/marketplace" "$TMP/state/installed" "$TMP/state/direct-installed" "$TMP/state/direct-stale"
  if [[ "${STUB_PREINSTALL_DIRECT:-0}" == "1" ]]; then
    touch "$TMP/state/direct-installed"
  fi
  if [[ "${STUB_STALE_DIRECT:-0}" == "1" ]]; then
    touch "$TMP/state/direct-stale"
  fi
  : > "$TMP/curl.log"
  PATH="$TMP/bin:$PATH" \
    STUB_LOG="$TMP/curl.log" \
    STUB_STATE="$TMP/state" \
    GITHUB_PAT="${GITHUB_PAT:-}" \
    SRE_PLUGIN_RESOLVE_ATTEMPTS=1 \
    SRE_PLUGIN_RESOLVE_DELAY_SECONDS=0 \
    SRE_PLUGIN_INSTALL_ATTEMPTS=1 \
    SRE_PLUGIN_INSTALL_DELAY_SECONDS=0 \
    bash bicep/apply-extras.sh sub rg agent "$TMP/extras.json"
}

if ! run_apply > "$TMP/success.log" 2>&1; then
  cat "$TMP/success.log" >&2
  exit 1
fi
grep -q $'POST\thttps://mock.agent/api/v2/plugins/marketplaces\t' "$TMP/curl.log"
grep -q $'GET\thttps://mock.agent/api/v2/plugins/marketplaces/test-marketplace/resolve\t' "$TMP/curl.log"
grep -q $'GET\thttps://mock.agent/api/v2/plugins/marketplaces/test-marketplace/plugins/test-plugin/skills\t' "$TMP/curl.log"
grep -q $'POST\thttps://mock.agent/api/v2/plugins/marketplaces/test-marketplace/plugins/test-plugin/install\t{"autoUpdate":false}' "$TMP/curl.log"
grep -q $'POST\thttps://mock.agent/api/v2/plugins/install-direct\t{"sourceUrl":"example/direct-skills","pathInRepo":"plugins/test-plugin"}' "$TMP/curl.log"
! grep -q $'POST\thttps://mock.agent/api/v2/plugins/installations\t' "$TMP/curl.log"
! grep -q $'DELETE\thttps://mock.agent/api/v2/plugins/installations/direct-installed\t' "$TMP/curl.log"

resolve_line=$(grep -n '/resolve' "$TMP/curl.log" | head -1 | cut -d: -f1)
install_line=$(grep -n '/install' "$TMP/curl.log" | tail -1 | cut -d: -f1)
[[ "$resolve_line" -lt "$install_line" ]]

GITHUB_PAT=test-token run_apply > "$TMP/pat.log" 2>&1
auth_line=$(grep -n $'PUT\thttps://mock.agent/api/v2/github/domains/github_com\t' "$TMP/curl.log" | cut -d: -f1)
marketplace_line=$(grep -n $'POST\thttps://mock.agent/api/v2/plugins/marketplaces\t' "$TMP/curl.log" | cut -d: -f1)
[[ "$auth_line" -lt "$marketplace_line" ]]
[[ $(grep -c $'PUT\thttps://mock.agent/api/v2/github/domains/github_com\t' "$TMP/curl.log") -eq 1 ]]

if STUB_UNEXPECTED_SKILL=1 run_apply > "$TMP/unexpected.log" 2>&1; then
  echo "unexpected skill import should fail" >&2
  exit 1
fi
grep -q 'would import unexpected skills' "$TMP/unexpected.log"

if STUB_RESOLVE_FAIL=1 run_apply > "$TMP/resolve-fail.log" 2>&1; then
  echo "marketplace resolution failure should fail" >&2
  exit 1
fi
grep -q 'clone failed' "$TMP/resolve-fail.log"

STUB_PREINSTALL_DIRECT=1 STUB_STALE_DIRECT=1 run_apply > "$TMP/direct-update.log" 2>&1
grep -q $'DELETE\thttps://mock.agent/api/v2/plugins/installations/direct-installed\t' "$TMP/curl.log"
grep -q $'POST\thttps://mock.agent/api/v2/plugins/install-direct\t{"sourceUrl":"example/direct-skills","pathInRepo":"plugins/test-plugin"}' "$TMP/curl.log"
grep -q 'updating to dev (fedcba987654)' "$TMP/direct-update.log"

if STUB_WRONG_DEFAULT=1 run_apply > "$TMP/wrong-default.log" 2>&1; then
  echo "direct install with the wrong default branch should fail" >&2
  exit 1
fi
grep -q 'must use dev as its default branch' "$TMP/wrong-default.log"

grep -q 'install-from-marketplace' bicep/Apply-Extras.ps1
grep -q 'install-direct' bicep/Apply-Extras.ps1
grep -q 'sourceRef' bicep/Apply-Extras.ps1
grep -q 'git ls-remote --symref' bicep/Apply-Extras.ps1
grep -q 'Invoke-DataPlaneJson -Method DELETE' bicep/Apply-Extras.ps1
grep -q 'plugins/marketplaces/$encodedMarketplace/plugins/$encodedPlugin' bicep/Apply-Extras.ps1
grep -q 'POST -Url "$pluginUrl/install"' bicep/Apply-Extras.ps1
grep -q 'api/v2/plugins/install-direct' bicep/Apply-Extras.ps1
grep -q 'Set-GitHubPat' bicep/Apply-Extras.ps1
grep -q "ValidateSet('GET', 'POST', 'PUT', 'DELETE')" bicep/Apply-Extras.ps1
grep -q 'Invoke-RestMethod .* -Method \$Method ' bicep/Apply-Extras.ps1

PATH="$TMP/bin:$PATH" \
  STUB_LOG="$TMP/curl.log" \
  STUB_STATE="$TMP/state" \
  bash bin/verify-agent.sh sub rg agent --expected "$TMP/expected" > "$TMP/verify.log" 2>&1
grep -q 'Required skills' "$TMP/verify.log"
grep -q 'Results: .*0 failed' "$TMP/verify.log"

if PATH="$TMP/bin:$PATH" \
  STUB_LOG="$TMP/curl.log" \
  STUB_STATE="$TMP/state" \
  STUB_MISSING_SKILL=1 \
  bash bin/verify-agent.sh sub rg agent --expected "$TMP/expected" > "$TMP/verify-missing.log" 2>&1; then
  echo "missing required skill should fail verification" >&2
  exit 1
fi
grep -q 'Required skills.*FAIL' "$TMP/verify-missing.log"

echo "Plugin marketplace lifecycle tests passed"
