resource "azurerm_linux_function_app" "this" {
  name                       = var.name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  service_plan_id            = var.service_plan_id
  storage_account_name       = var.storage_account_name
  storage_account_access_key = var.storage_account_access_key
  https_only                 = true
  functions_extension_version = "~4"
  tags                       = var.tags

  identity { type = "SystemAssigned" }

  site_config {
    application_stack { python_version = "3.11" }
    minimum_tls_version = "1.2"
  }

  app_settings = merge(var.app_settings, {
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = var.application_insights_connection_string
    "SCM_DO_BUILD_DURING_DEPLOYMENT"     = "true"
    "ENABLE_ORYX_BUILD"                 = "true"
  })
}
