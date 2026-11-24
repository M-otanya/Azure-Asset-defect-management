variable "subscription_id" {
  description = "Target Azure subscription. Set via TF_VAR_subscription_id from deploy.ps1."
  type        = string
}
variable "resource_group_name" {
  description = "Existing Azure resource group. This project does not recreate it."
  type        = string
  default     = "asset-defect-dev-rg"
}
variable "location" {
  description = "Azure region for all new resources."
  type        = string
  default     = "eastus2"
}
variable "environment" {
  type    = string
  default = "dev"
}
variable "slack_workspace_id" {
  description = "Immutable Slack workspace/team ID, e.g. T0123456789. Not a secret."
  type        = string
}
variable "defect_ai_required" {
  description = "Fail closed when the optional Azure OpenAI review cannot run. Defaults to false."
  type        = bool
  default     = false
}
variable "azure_openai_endpoint" {
  description = "Optional existing Azure OpenAI endpoint; empty disables AI review."
  type        = string
  default     = ""
}
variable "azure_openai_deployment" {
  description = "Optional model deployment name; not created by this baseline."
  type        = string
  default     = ""
}
variable "tags" {
  type = map(string)
  default = {
    project     = "asset-defect"
    environment = "dev"
    managed_by  = "terraform"
  }
}
