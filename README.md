# Asset Approval and Defect Management — Azure

This is an **Azure port of the real AWS Terraform repository** `M-otanya/Asset-Aproval-and-Defect-Management.` (the final period is part of the GitHub repository name), using the source as of 19 November 2026. It is an infrastructure-and-code migration, not a rename of AWS resources. **It has not been deployed into your Azure subscription by the author; run `terraform plan` and review Azure charges before approving creation.**

## What is preserved

- `/asset-agent`: verified Slack command → isolated Service Bus queue → asset Function → Cosmos session/event → Slack notification.
- `/defect-agent`: verified Slack command → operator authorization in Cosmos → isolated Service Bus queue → read-only Jira Function → risk note → Cosmos proposal → Slack **Confirm / Cancel** buttons.
- Confirm/Cancel → separate action queue → independent Jira executor Function → **authorization recheck**, **atomic proposal claim**, and **Jira write token** only on confirmed updates.
- Separate read and write Jira tokens; exact AWS credential JSON payloads can be reused, stored securely in **three Azure Key Vaults**. Terraform does not store their values.
- Source's default fail-open advisory review: if optional Azure OpenAI is not configured, risk is `UNASSESSED`, and a human must still confirm.
- The AWS source has a **placeholder asset AI harness integration**, so this port also records asset requests but does not implement asset AI execution.

## Service translation

| AWS source | Azure port |
|---|---|
| Lambda (ingress, asset worker, defect worker, Jira executor) | Four separate Azure Function Apps (Python 3.11) |
| SQS asset/defect queues | Service Bus `asset-requests`, `defect-requests` queues |
| Lambda asynchronous invoke for Confirm/Cancel | Service Bus `defect-actions` queue |
| API Gateway HTTP API | Anonymous Function HTTP routes, authenticated by Slack HMAC |
| Five DynamoDB tables | Five Cosmos DB for NoSQL containers |
| Three Secrets Manager credentials | Three Azure Key Vaults (`credentials` secret in each) |
| CloudWatch | Application Insights |
| IAM roles and policies | Per-Function managed identities, Service Bus RBAC, Cosmos data RBAC, Key Vault RBAC |
| Bedrock AgentCore harness | Optional Azure OpenAI risk review adapter; **not auto-provisioned** |
| S3 Terraform state | Local state for first deployment; migrate to Azure Blob for collaboration |

**No VM, Cognito, or additional Entra user account is needed.** The existing resource group `asset-defect-dev-rg` in `eastus2` is reused, and the script authenticates with your existing Azure login.

## 1. Install local tools (Windows PowerShell)

Install:

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows)
- [Terraform](https://developer.hashicorp.com/terraform/install) (1.6+)
- [Python 3.11](https://www.python.org/downloads/) (use it for local Functions)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local)
- Optional for local host: [Azurite](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azurite) (install `npm install -g azurite`)

Open a **new LOCAL Windows PowerShell** terminal (not necessary to create a separate Azure user). If Windows blocks scripts, run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Authenticate and choose the subscription you already created:

```powershell
az login --use-device-code
az account set --subscription "<YOUR-SUBSCRIPTION-ID>"
az account show --output table
terraform version
func --version
```

Terraform will use the Azure CLI login via `ARM_SUBSCRIPTION_ID`; an app registration / service principal is **not** needed for a local interactive deployment. If `az account show` works but `terraform` fails with 403, check your subscription has **Owner** permissions or both Contributor and User Access Administrator / Role Based Access Control Administrator. Terraform creates RBAC role assignments for managed identities.

## 2. Deploy from your Windows computer

Extract the ZIP. In PowerShell, change to the extracted folder. Replace `T...` with your Slack workspace/team ID:

```powershell
cd "$HOME\Downloads\asset-defect-azure"
.\deploy.ps1 -SlackWorkspaceId "T0123456789"
```

The script registers required providers, runs `terraform init`, `terraform validate`, `terraform plan`, asks you to type **APPLY** before spending money, creates the Azure infrastructure, creates a local Python virtual environment if needed, and publishes the four Function Apps. If you want infrastructure only (publish manually later):

```powershell
.\deploy.ps1 -SlackWorkspaceId "T0123456789" -SkipPublish
```

If you are *deliberately* automating the confirmation, add `-AutoApprove` (not advised for the first run).

**Important:** The project has metered services. Cosmos DB serverless, Service Bus Basic, Key Vault, Storage, and Application Insights can incur costs even at low usage. Check Azure pricing and set a budget alert. `terraform plan` is not a price estimate. Subscription policies, RBAC replication, and regional service capacity can cause first deployment attempts to fail. Fix the reported issue and re-run the script.

## 3. Reuse the existing Slack/Jira credentials

Terraform creates the empty Key Vaults **without any secret values**. Transfer your existing AWS Secrets Manager values securely by running:

```powershell
.\scripts\set-secrets.ps1
```

It prompts privately for:

1. **Slack signing secret** from the existing Slack app.
2. **Jira Cloud ID**, project key (e.g. `SCRUM`), and existing scoped **read-only Jira token**.
3. Existing scoped **Jira write token**.

The script writes the following JSON schemas into the Key Vault secret named `credentials`:

```json
{"signing_secret":"<existing-Slack-signing-secret>"}
{"api_token":"<existing-read-token>","cloud_id":"<Jira-cloud-id>","project_key":"SCRUM"}
{"api_token":"<existing-write-token>","cloud_id":"<Jira-cloud-id>","project_key":"SCRUM"}
```

The above are **examples only**. The actual secrets are prompted, written to temporary files for `az keyvault secret set --file`, then those files are deleted. Never store them in Git, `terraform.tfvars`, deployment output, or chat. **Use the same Atlassian scoped Bearer API tokens as in the AWS project**; a classic Basic-auth token needs different request code. If Key Vault returns 403 shortly after Terraform completes, allow RBAC assignments to propagate and retry.

## 4. Authorize a Slack operator

Use the existing Slack member ID of the person who may Confirm or Cancel Jira proposals (e.g. `U0123456789`):

```powershell
python -m pip install -r .\scripts\requirements.txt
python .\scripts\authorize-user.py U0123456789
```

This creates Cosmos NoSQL document `{ "id": "U0123456789", "enabled": true, "role": "defect_operator" }` in `defect-authorization`. The Terraform deployment grants the signed-in local developer Cosmos access for this setup. To revoke later:

```powershell
python .\scripts\authorize-user.py U0123456789 --disable
```

## 5. Configure Slack endpoints

From the ZIP root:

```powershell
terraform -chdir=infrastructure output -raw slack_commands_url
terraform -chdir=infrastructure output -raw slack_interactions_url
```

In your **existing Slack app**, set both `/asset-agent` and `/defect-agent` slash commands to **slack_commands_url**. Under **Interactivity & Shortcuts**, set Request URL to **slack_interactions_url**. No new Slack app or Jira project is necessary.

Test in Slack:

```text
/defect-agent SCRUM-5 priority=Low
```

The system should fetch issue `SCRUM-5`, return a reviewable proposal (risk `UNASSESSED` until AI is configured), and wait for Confirm or Cancel. Test **Cancel first**. Then create a separate proposal and Confirm if you intend to change the Jira priority. Only the executor Function has the Jira write secret.

Also try:

```text
/asset-agent Request a replacement laptop
```

This records a session and acknowledges it; it does **not** perform a full asset approval decision because the AWS source did not implement that stage.

## 6. Run Functions locally, not just deploy from local Terraform

**Local Functions need the deployed Azure queues, Key Vaults, and Cosmos account**; they do not emulate those services. First complete steps 1–4. Start Azurite (local Functions host storage emulator) in one terminal:

```powershell
azurite --silent
```

In a second terminal at project root:

```powershell
.\scripts\prepare-local.ps1 -SlackWorkspaceId "T0123456789"
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r .\applications\ingress\requirements.txt
```

Start each Function App from its folder using a **different terminal** and **different port** (activate the same root `.venv` in each):

| Terminal | Working directory | Command |
|---|---|---|
| 1 | `applications\ingress` | `func start --port 7071` |
| 2 | `applications\asset_worker` | `func start --port 7072` |
| 3 | `applications\defect_worker` | `func start --port 7073` |
| 4 | `applications\jira_executor` | `func start --port 7074` |

To open one terminal for the ingress Function:

```powershell
cd .\applications\ingress
func start --port 7071
```

Do not leave deployed workers and local workers running against the same queues during testing: they are competing consumers. Disable the deployed queue-trigger Functions during local-only end-to-end runs, or use a separate Azure test environment.

The local HTTP URL is `http://localhost:7071/api/slack/commands`. A simple unsigned POST should return **401**, which is expected because Slack HMAC signing is mandatory. For real Slack webhook testing, use the **deployed HTTPS endpoint** above, or configure a secure HTTPS tunnel; Slack cannot reach `localhost` directly. Use the same `az login` in your local shell; Azure SDK DefaultAzureCredential will use Azure CLI authentication locally, and managed identity in deployed Functions.

## 7. Optional Azure AI advisory review

The source AWS deployment created a Bedrock AgentCore **defect-review harness**. There is no automatic one-for-one translation of that harness to Azure. This baseline has a functional review adapter but **does not provision an Azure OpenAI model deployment**, because model availability, quotas, and charges depend on your subscription and region.

When you have an existing Azure OpenAI compatible endpoint/model deployment, set Terraform variables:

```hcl
azure_openai_endpoint   = "https://YOUR_RESOURCE.openai.azure.com"
azure_openai_deployment = "YOUR_DEPLOYMENT_NAME"
defect_ai_required      = false
```

Grant **Cognitive Services OpenAI User** to the defect-worker Function's managed identity on that existing AI resource. Reapply Terraform and republish the Function if the code changes. The adapter calls the chat completions endpoint using managed identity. It sees only Jira issue summary/status/current priority/proposed priority and whether assignment would change. It never gets Jira tokens or update permissions. Confirm remains mandatory.

## 8. Test and clean up

Run offline Python contract tests without AWS/Azure credentials:

```powershell
python -m unittest discover -s tests -v
```

View function logs in Azure Portal → Function Apps → Monitor / Application Insights. Check Service Bus dead-letter queues for failed messages. The original AWS workflow and this port are not exact database/API clones; validate the actual tenant, tokens, permissions, quotas and Jira project priority names before production use.

To remove all Terraform-managed resources (your preexisting resource group is retained):

```powershell
.\destroy.ps1
```

This deletes data, queues, Functions, and Key Vault resources managed by this Terraform state. Vaults may remain soft-deleted for their retention period. **Do not delete Terraform state before `destroy`.**

## Caveats and security

- Azure managed identities exist automatically on Function Apps. **You need no new Entra user or permanent client secret** for this local workflow.
- Cosmos serverless and Service Bus Basic may be unavailable/limited under subscription or region quotas. An Azure service deployment failure is not a Terraform translation error by itself.
- The application uses Azure Function consumption hosting; cold starts can affect Slack's three-second acknowledgement deadline. For production, evaluate always-ready compute and ingress latency budgets.
- Function host Storage Account access keys and other resource-generated values can appear in **Terraform state**, even though the Slack/Jira secret **values do not**. Protect state and migrate to encrypted remote Azure Blob state before collaboration / GitHub Actions.
- For reliable delivery, Service Bus retries and dead-lettering are enabled, but external Jira changes cannot be rolled back automatically. Investigate proposals marked `FAILED` rather than automatically replaying Confirm.
- No GitHub Actions OIDC automation has been configured here. Local deployment deliberately uses `az login`; CI should use workload-identity federation, not a password or user token.
- Do not turn on `defect_ai_required=true` until the Azure AI endpoint and role permissions actually work.
