# Adds the existing AWS Slack/Jira JSON credential payloads to three isolated Azure Key Vaults.
# Secure prompts keep tokens out of shell command history. Azure CLI reads a short-lived temp file.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$infra = Join-Path (Split-Path -Parent $PSScriptRoot) 'infrastructure'
function Output($name) {
    $result = terraform "-chdir=$infra" output -raw $name
    if ($LASTEXITCODE -ne 0) { throw "Missing Terraform output $name" }
    return $result.Trim()
}
function SecureText($prompt) {
    $secure = Read-Host -Prompt $prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function SaveSecret($vault, $data) {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("az-secret-" + [Guid]::NewGuid().ToString() + '.json')
    try {
        $value = $data | ConvertTo-Json -Compress -Depth 5
        [IO.File]::WriteAllText($temp, $value, ([System.Text.UTF8Encoding]::new($false)))
        az keyvault secret set --vault-name $vault --name credentials --file $temp --output none
        if ($LASTEXITCODE -ne 0) { throw "Could not populate vault $vault" }
        Write-Host "Secret stored in $vault"
    }
    finally {
        if (Test-Path $temp) { Remove-Item $temp -Force }
    }
}
Write-Host 'Enter the current Slack Signing Secret from your existing AWS deployment.'
$slack = SecureText 'Slack signing secret'
SaveSecret (Output 'slack_key_vault') @{ signing_secret = $slack }
Remove-Variable slack
$cloudId = Read-Host 'Jira Cloud ID (same as AWS secret)'
$projectKey = Read-Host 'Jira project key (SCRUM)'
$readToken = SecureText 'Jira READ scoped API token'
SaveSecret (Output 'jira_read_key_vault') @{ api_token = $readToken; cloud_id = $cloudId; project_key = $projectKey }
Remove-Variable readToken
$writeToken = SecureText 'Jira WRITE scoped API token'
SaveSecret (Output 'jira_write_key_vault') @{ api_token = $writeToken; cloud_id = $cloudId; project_key = $projectKey }
Remove-Variable writeToken
Write-Host 'Credential migration complete. Do not print or commit secret values.'
