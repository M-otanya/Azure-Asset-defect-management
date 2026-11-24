# Deploy from a WINDOWS LOCAL PowerShell terminal. Requires Azure CLI, Terraform and Functions Core Tools.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^T[A-Z0-9]+$')][string]$SlackWorkspaceId,
    [string]$SubscriptionId = '',
    [switch]$AutoApprove,
    [switch]$SkipPublish
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$infra = Join-Path $root 'infrastructure'
function Check($tool) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing '$tool'. Install it before running deploy.ps1." }
}
Check 'az'
Check 'terraform'
if (-not $SkipPublish) {
    Check 'func'
    Check 'python'
    $venv = Join-Path $root '.venv'
    $pythonExe = Join-Path $venv 'Scripts/python.exe'
    if (-not (Test-Path $pythonExe)) {
        python -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw 'Could not create Python virtual environment' }
    }
    $env:VIRTUAL_ENV = $venv
    $env:PATH = (Join-Path $venv 'Scripts') + ';' + $env:PATH
}
$session = az account show --output json 2>$null | ConvertFrom-Json
if (-not $session) {
    Write-Host 'Azure CLI login required. Complete MFA in your browser.'
    az login --use-device-code | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'az login failed' }
    $session = az account show --output json | ConvertFrom-Json
}
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw 'Could not select subscription' }
    $session = az account show --output json | ConvertFrom-Json
}
$env:ARM_SUBSCRIPTION_ID = $session.id
$env:TF_VAR_subscription_id = $session.id
$env:TF_VAR_slack_workspace_id = $SlackWorkspaceId
Write-Host "Using subscription $($session.id) and existing resource group asset-defect-dev-rg"
foreach ($provider in @('Microsoft.Web','Microsoft.Storage','Microsoft.ServiceBus','Microsoft.KeyVault','Microsoft.DocumentDB','Microsoft.Insights')) {
    az provider register --namespace $provider --output none
    if ($LASTEXITCODE -ne 0) { throw "Provider registration failed: $provider" }
}
Push-Location $infra
try {
    terraform init
    if ($LASTEXITCODE -ne 0) { throw 'terraform init failed' }
    terraform validate
    if ($LASTEXITCODE -ne 0) { throw 'terraform validate failed' }
    terraform plan -out=tfplan
    if ($LASTEXITCODE -ne 0) { throw 'terraform plan failed' }
    if (-not $AutoApprove) {
        $answer = Read-Host 'Terraform will create billable Azure resources. Type APPLY to proceed'
        if ($answer -cne 'APPLY') { Write-Host 'Plan only. Nothing deployed.'; return }
    }
    terraform apply tfplan
    if ($LASTEXITCODE -ne 0) { throw 'terraform apply failed' }
    $names = @{
        ingress       = (terraform output -raw ingress_function_app)
        asset_worker  = (terraform output -raw asset_worker_function_app)
        defect_worker = (terraform output -raw defect_worker_function_app)
        jira_executor = (terraform output -raw jira_executor_function_app)
    }
    Write-Host 'Azure infrastructure created.'
    if (-not $SkipPublish) {
        foreach ($role in @('ingress','asset_worker','defect_worker','jira_executor')) {
            $dir = Join-Path $root "applications/$role"
            $common = Join-Path $dir 'common'
            if (Test-Path $common) { Remove-Item $common -Recurse -Force }
            Copy-Item (Join-Path $root 'applications/common') $common -Recurse -Force
            Push-Location $dir
            try {
                Write-Host "Publishing $role to $($names[$role])"
                func azure functionapp publish $names[$role]
                if ($LASTEXITCODE -ne 0) { throw "Function publish failed: $role" }
            }
            finally { Pop-Location }
        }
    }
    Write-Host ''
    Write-Host 'Slack Commands URL:'
    terraform output -raw slack_commands_url
    Write-Host 'Slack Interactivity URL:'
    terraform output -raw slack_interactions_url
    Write-Host ''
    Write-Host 'NEXT: Run .\scripts\set-secrets.ps1, authorize a Slack user, and configure Slack URLs.'
}
finally { Pop-Location }
