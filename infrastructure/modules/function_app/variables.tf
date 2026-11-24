variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "service_plan_id" { type = string }
variable "storage_account_name" { type = string }
variable "storage_account_access_key" {
  type      = string
  sensitive = true
}
variable "application_insights_connection_string" {
  type      = string
  sensitive = true
}
variable "app_settings" { type = map(string) }
variable "tags" { type = map(string) }
