# Repository execution policy

- Use PowerShell for all repository execution and validation.
- Do not create or run shell scripts (`*.sh`) in this repository.
- Do not invoke Azure CLI (`az`) from PowerShell. Use Az PowerShell cmdlets
  with an explicit subscription context.
- Use `sreagent-templates/bicep/Apply-Extras.ps1` for the apply-extras
  lifecycle.
