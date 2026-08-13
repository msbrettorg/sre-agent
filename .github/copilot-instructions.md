# Copilot instructions for sre-agent

This repo is the community hub for Azure SRE Agent. It has two independent development surfaces
with **no shared root build system**:

- `sreagent-templates/` — the reusable recipe/IaC toolkit for deploying SRE Agents as code (Bicep,
  Terraform, azd, bash + PowerShell CLIs). This is where most code changes happen.
- `labs/` — standalone deployable/demo projects; consult each lab's own documentation for
  setup/usage, and its nested `AGENTS.md` when present (see hierarchy below).

## Instruction hierarchy

More specific guidance always wins:

1. `labs/zava-learning/AGENTS.md` — conventions for that lab (symptom-only alerts, skill routing,
   remediation boundaries, PR/change-management flow). Applies only within `labs/zava-learning/`.
2. `labs/zava-aks-postgres/AGENTS.md` — conventions for that lab (setup flow, break/fix scenarios,
   agent behavior). Applies only within `labs/zava-aks-postgres/`.
3. `sreagent-templates/CONTRIBUTING.md` — recipe design, YAML shapes, and required-files rules.
   Applies only within `sreagent-templates/`.
4. This file — repo-wide fallback when no closer guidance exists.

For labs with no nested `AGENTS.md`, fall back to that lab's own documentation (e.g. its
`README.md`, where one exists) for setup and conventions.

## Mandatory execution boundary

- Read and follow the approved session plan before making changes. Perform only work explicitly
  listed in that plan; any scope change requires explicit user approval and a plan update first.
- For `sreagent-templates/` work, the only approved implementation paths are those documented in
  this repository. Use `sreagent-templates/CONTRIBUTING.md`, repository README files, existing
  recipe examples, and the canonical scripts under `sreagent-templates/bin/` and
  `sreagent-templates/bicep/`.
- Azure MCP Server read-only inspection is allowed to confirm that canonically deployed resources,
  connectors, tools, and configuration work as expected.
- Do not use Azure MCP Server write operations to create, update, delete, or deploy this
  repository's resources. Do not use MCP schemas, external implementation examples, or inferred
  connector fields to design recipe connectors.
- Do not bypass or replace the repository's documented recipe lifecycle with direct Azure resource
  operations. Generate through `bin/new-agent.sh`, deploy through `bin/deploy.sh`, and apply
  data-plane assets through the existing `bicep/apply-extras.sh` lifecycle.
- If the repository documentation does not define a required connector shape or operation, stop
  and report that repository-local blocker. Do not fill the gap with external research or guesses.

## Architecture: `sreagent-templates/`

Recipes under `recipes/<name>/` are the unit of reuse. A conforming recipe includes `agent.json`,
`connectors.json`, its `config/` and `automations/` assets, and `expected-config.json` as the
verification spec; see `CONTRIBUTING.md` for the conditional and recommended assets. Secrets
belong only in `connectors.secrets.env`, which must remain gitignored and uncommitted.

There are two entry paths for creating assets:

1. `bin/new-agent.sh` (or `bin/ps/New-Agent.ps1`) stamps a recipe into a human-editable config
   directory (`agent.json`, `connectors.json`, `connectors.secrets.env`, `config/`, `automations/`).
2. `bin/add-recipe.sh` (or `bin/ps/Add-Recipe.ps1`) adds recipe components to an existing agent
   config without replacing its identity, access, or model settings. It skips duplicate connectors
   and produces a merged config directory ready for the normal deployment path.

Both entry paths then use the same lifecycle:

1. `bicep/assemble-agent.sh` (or `bicep/Assemble-Agent.ps1`) resolves secret references
   (`connectors.secrets.env`) and Markdown file references (skills/subagents), emitting generated
   `<dir>.parameters.json` (Bicep-deployable) and `<dir>.extras.json` (data-plane config).
2. `bin/deploy.sh` or `bin/deploy-tf.sh` (bash) / `bin/ps/Deploy-Agent.ps1` / `Deploy-Tf.ps1`
   (PowerShell) deploys the infrastructure (Bicep under `bicep/`, or Terraform under `terraform/`).
3. `bicep/apply-extras.sh` (or `Apply-Extras.ps1`) applies data-plane/ARM sub-resources (connectors,
   hooks, scheduled tasks, common prompts, repos, incident filters). This is normally invoked
   automatically by the deploy scripts, not run standalone.
4. Lifecycle management: `bin/verify-agent.sh` (spec-driven verification against a live agent),
   `bin/diff-agent.sh` (config vs. live agent), `bin/export-agent.sh` (live agent → config
   directory), `bin/clone-agent.sh` (export → validate → deploy). Each has a `bin/ps/*.ps1`
   equivalent, and PowerShell scripts are intended to stay behaviorally equivalent to their bash
   counterparts — update both when changing shared behavior.

See `sreagent-templates/docs/ARCHITECTURE.md` for the full directory map and
`sreagent-templates/README.md` for the CLI reference table.

## Build / lint / test (from repository root)

There is no root-level build. All commands below are scoped to `sreagent-templates/`.

```bash
cd sreagent-templates

# Focused test — one recipe (azmon-lawappinsights) across all backends (Bicep, Terraform, azd, PS)
bash tests/test-dry-run-azmon.sh

# Full suite — all recipes' dry-run tests
bash tests/test-dry-run-all.sh
```

Other focused tests follow `tests/test-dry-run-*.sh`. Dedicated PowerShell end-to-end coverage is
under `tests/e2e/test-*-ps.sh`; do not treat PowerShell as untested when reviewing coverage.

`.github/workflows/validate-templates.yml` is the canonical CI validation (job working directory:
`sreagent-templates`). These concise local equivalents cover its core syntax checks:

```bash
cd sreagent-templates

# YAML lint — every recipe YAML file must parse
for f in $(find recipes/ -name '*.yaml' -o -name '*.yml'); do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" || exit 1
done

# Bash syntax check
for f in bin/*.sh bicep/*.sh; do bash -n "$f" || exit 1; done

# PowerShell parser check (requires pwsh)
for f in bin/ps/*.ps1; do
  pwsh -NoProfile -Command "\$errs=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$f', [ref]\$null, [ref]\$errs); if(\$errs){\$errs; exit 1}"
done

# Terraform validate (requires terraform)
(cd terraform && terraform init -backend=false -input=false && terraform validate)
```

The workflow is authoritative for full error aggregation, PowerShell exception handling,
changed-recipe selection, and README checks. Consult it directly rather than reproducing that
logic here.

## Recipe conventions (`sreagent-templates/CONTRIBUTING.md`)

- Recipe names: `<platform>-<key-connectors>[-variant]` (e.g. `azmon-lawappinsights`).
- Secrets go only in `connectors.secrets.env` (gitignored) — never in YAML or JSON.
- Toggle-managed connectors (e.g. `enableAppInsightsConnector`) go only in `connectors.json`; do not
  also create a connector YAML file for a toggle-managed connector.
- Skill file references: `skillContent: skills/<name>.md` (directory prefix required for
  `resolve_file_refs` to locate the file).
- Subagent file references: `spec.instructions: subagents/<name>.instructions.md`.
- Hooks use `spec.hook.type` / `spec.hook.prompt` / `spec.hook.matcher` (not `hookType`/`hookBody`,
  which is a Bicep-internal shape, not the API shape).
- The Azure Monitor incident-platform value is exactly `AzMonitor` (not `AzureMonitor`).
- Per `CONTRIBUTING.md`, recipe changes must keep `expected-config.json`, dry-run coverage,
  `CHANGELOG.md`, and `VERSION` handling aligned.
- CI also requires the recipe `README.md` sections `## Quick Start`, `## Parameters`, and
  `## What You Get`, and checks `_prompts` keys from `agent.json` against the README; see
  `.github/workflows/validate-templates.yml` for the authoritative checks.
