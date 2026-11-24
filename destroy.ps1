# Tear down this Terraform project, leaving the existing resource group untouched.
$ErrorActionPreference = 'Stop'
$infra = Join-Path $PSScriptRoot 'infrastructure'
$env:ARM_SUBSCRIPTION_ID = (az account show --query id --output tsv).Trim()
$env:TF_VAR_subscription_id = $env:ARM_SUBSCRIPTION_ID
# Supply the same non-secret Slack workspace ID used for the original deployment.
$env:TF_VAR_slack_workspace_id = Read-Host 'Slack workspace ID (e.g. T...)'
terraform "-chdir=$infra" destroy
if ($LASTEXITCODE -ne 0) { throw 'Terraform destroy failed' }
Write-Host 'Application resources removed. Existing resource group was not deleted.'
