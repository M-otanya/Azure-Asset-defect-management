# Prepare local.settings.json for all four Functions (no secrets saved).
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SlackWorkspaceId)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$infra = Join-Path $root 'infrastructure'
function Output($name) {
    $r = terraform "-chdir=$infra" output -raw $name
    if ($LASTEXITCODE -ne 0) { throw "Missing Terraform output $name" }
    return $r.Trim()
}
$common = @{
    'FUNCTIONS_WORKER_RUNTIME' = 'python'
    'AzureWebJobsStorage' = 'UseDevelopmentStorage=true'
    'COSMOS_ENDPOINT' = (Output cosmos_endpoint)
    'COSMOS_DATABASE' = (Output cosmos_database)
    'ServiceBusConnection__fullyQualifiedNamespace' = (Output servicebus_namespace)
}
$base = @{
    ingress = @{
        SLACK_WORKSPACE_ID = $SlackWorkspaceId
        SLACK_VAULT_URL = ('https://' + (Output slack_key_vault) + '.vault.azure.net/')
        AUTH_CONTAINER = (Output cosmos_authorization_container)
        ASSET_QUEUE_NAME = 'asset-requests'
        DEFECT_QUEUE_NAME = 'defect-requests'
        ACTION_QUEUE_NAME = 'defect-actions'
    }
    asset_worker = @{
        ASSET_QUEUE_NAME = 'asset-requests'
        SESSION_CONTAINER = 'asset-sessions'
        EVENT_CONTAINER = 'asset-events'
    }
    defect_worker = @{
        DEFECT_QUEUE_NAME = 'defect-requests'
        JIRA_READ_VAULT_URL = ('https://' + (Output jira_read_key_vault) + '.vault.azure.net/')
        PROPOSAL_CONTAINER = 'defect-proposals'
        EVENT_CONTAINER = 'defect-events'
        DEFECT_AI_REQUIRED = 'false'
        AZURE_OPENAI_ENDPOINT = ''
        AZURE_OPENAI_DEPLOYMENT = ''
    }
    jira_executor = @{
        ACTION_QUEUE_NAME = 'defect-actions'
        JIRA_WRITE_VAULT_URL = ('https://' + (Output jira_write_key_vault) + '.vault.azure.net/')
        AUTH_CONTAINER = (Output cosmos_authorization_container)
        PROPOSAL_CONTAINER = 'defect-proposals'
    }
}
foreach ($role in @('ingress','asset_worker','defect_worker','jira_executor')) {
    $dir = Join-Path $root "applications/$role"
    $commonDest = Join-Path $dir 'common'
    if (Test-Path $commonDest) { Remove-Item $commonDest -Recurse -Force }
    Copy-Item (Join-Path $root 'applications/common') $commonDest -Recurse -Force
    $values = @{} + $common
    foreach ($key in $base[$role].Keys) { $values[$key] = $base[$role][$key] }
    $json = @{ IsEncrypted = $false; Values = $values } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $dir 'local.settings.json'), $json, ([System.Text.UTF8Encoding]::new($false)))
    Write-Host "Prepared $role local.settings.json"
}
Write-Host 'Start Azurite, then run func start from each applications/<role> folder using distinct ports.'
