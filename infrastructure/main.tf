data "azurerm_client_config" "current" {}
data "azurerm_resource_group" "existing" {
  name = var.resource_group_name
}

resource "random_string" "suffix" {
  length  = 7
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix   = random_string.suffix.result
  prefix   = "ad-${var.environment}"
  rg_name  = data.azurerm_resource_group.existing.name
  location = var.location
  db_name  = "asset-defect-${var.environment}"
  containers = {
    asset_sessions       = "asset-sessions"
    asset_events         = "asset-events"
    defect_events        = "defect-events"
    defect_authorization = "defect-authorization"
    defect_proposals     = "defect-proposals"
  }
  queues = {
    asset_requests  = "asset-requests"
    defect_requests = "defect-requests"
    defect_actions  = "defect-actions"
  }
  secret_vaults = {
    slack      = "${local.prefix}-slack-${local.suffix}"
    jira_read  = "${local.prefix}-jread-${local.suffix}"
    jira_write = "${local.prefix}-jwrite-${local.suffix}"
  }
}

# Azure Storage supports the Functions host. Existing resource group is reused.
resource "azurerm_storage_account" "functions" {
  name                     = "ad${var.environment}st${local.suffix}"
  resource_group_name      = local.rg_name
  location                 = local.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags = var.tags
}

resource "azurerm_service_plan" "consumption" {
  name                = "${local.prefix}-functions-plan"
  resource_group_name = local.rg_name
  location            = local.location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = var.tags
}

resource "azurerm_application_insights" "monitoring" {
  name                = "${local.prefix}-insights"
  resource_group_name = local.rg_name
  location            = local.location
  application_type    = "web"
  tags                = var.tags
}

resource "azurerm_servicebus_namespace" "main" {
  name                = "${local.prefix}-bus-${local.suffix}"
  location            = local.location
  resource_group_name = local.rg_name
  sku                 = "Basic"
  tags                = var.tags
}

resource "azurerm_servicebus_queue" "queues" {
  for_each                             = local.queues
  name                                 = each.value
  namespace_id                         = azurerm_servicebus_namespace.main.id
  max_delivery_count                   = 5
  dead_lettering_on_message_expiration = true
}

# Serverless Cosmos DB is metered. Container TTL matches DynamoDB expiration semantics.
resource "azurerm_cosmosdb_account" "main" {
  name                = "ad${var.environment}cosmos${local.suffix}"
  location            = local.location
  resource_group_name = local.rg_name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  local_authentication_disabled = true
  public_network_access_enabled = true
  capabilities { name = "EnableServerless" }
  consistency_policy { consistency_level = "Session" }
  geo_location {
    location          = local.location
    failover_priority = 0
  }
  tags = var.tags
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name                = local.db_name
  resource_group_name = local.rg_name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "containers" {
  for_each            = local.containers
  name                = each.value
  resource_group_name = local.rg_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/id"]
  partition_key_version = 2
  default_ttl         = -1
}

# Three vaults keep Slack, Jira-read, and Jira-write credentials isolated.
# Secret *values* are NOT managed by Terraform; set-secrets.ps1 adds them afterwards.
resource "azurerm_key_vault" "secrets" {
  for_each                     = local.secret_vaults
  name                         = each.value
  location                     = local.location
  resource_group_name          = local.rg_name
  tenant_id                    = data.azurerm_client_config.current.tenant_id
  sku_name                     = "standard"
  enable_rbac_authorization    = true
  soft_delete_retention_days   = 7
  purge_protection_enabled     = false
  tags                         = var.tags
}

# Creator needs Key Vault data-plane permission to add secrets post-deployment.
resource "azurerm_role_assignment" "operator_vault" {
  for_each             = azurerm_key_vault.secrets
  scope                = each.value.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

locals {
  common_env = {
    COSMOS_ENDPOINT = azurerm_cosmosdb_account.main.endpoint
    COSMOS_DATABASE = azurerm_cosmosdb_sql_database.main.name
  }
  bus_env = {
    "ServiceBusConnection__fullyQualifiedNamespace" = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
  }
}

module "ingress" {
  source                                = "./modules/function_app"
  name                                  = "${local.prefix}-ingress-${local.suffix}"
  location                              = local.location
  resource_group_name                   = local.rg_name
  service_plan_id                       = azurerm_service_plan.consumption.id
  storage_account_name                  = azurerm_storage_account.functions.name
  storage_account_access_key            = azurerm_storage_account.functions.primary_access_key
  application_insights_connection_string = azurerm_application_insights.monitoring.connection_string
  app_settings = merge(local.common_env, local.bus_env, {
    SLACK_WORKSPACE_ID  = var.slack_workspace_id
    SLACK_VAULT_URL     = azurerm_key_vault.secrets["slack"].vault_uri
    AUTH_CONTAINER      = azurerm_cosmosdb_sql_container.containers["defect_authorization"].name
    ASSET_QUEUE_NAME    = azurerm_servicebus_queue.queues["asset_requests"].name
    DEFECT_QUEUE_NAME   = azurerm_servicebus_queue.queues["defect_requests"].name
    ACTION_QUEUE_NAME   = azurerm_servicebus_queue.queues["defect_actions"].name
  })
  tags = var.tags
}

module "asset_worker" {
  source                                = "./modules/function_app"
  name                                  = "${local.prefix}-asset-worker-${local.suffix}"
  location                              = local.location
  resource_group_name                   = local.rg_name
  service_plan_id                       = azurerm_service_plan.consumption.id
  storage_account_name                  = azurerm_storage_account.functions.name
  storage_account_access_key            = azurerm_storage_account.functions.primary_access_key
  application_insights_connection_string = azurerm_application_insights.monitoring.connection_string
  app_settings = merge(local.common_env, local.bus_env, {
    ASSET_QUEUE_NAME       = azurerm_servicebus_queue.queues["asset_requests"].name
    SESSION_CONTAINER      = azurerm_cosmosdb_sql_container.containers["asset_sessions"].name
    EVENT_CONTAINER        = azurerm_cosmosdb_sql_container.containers["asset_events"].name
  })
  tags = var.tags
}

module "defect_worker" {
  source                                = "./modules/function_app"
  name                                  = "${local.prefix}-defect-worker-${local.suffix}"
  location                              = local.location
  resource_group_name                   = local.rg_name
  service_plan_id                       = azurerm_service_plan.consumption.id
  storage_account_name                  = azurerm_storage_account.functions.name
  storage_account_access_key            = azurerm_storage_account.functions.primary_access_key
  application_insights_connection_string = azurerm_application_insights.monitoring.connection_string
  app_settings = merge(local.common_env, local.bus_env, {
    DEFECT_QUEUE_NAME       = azurerm_servicebus_queue.queues["defect_requests"].name
    JIRA_READ_VAULT_URL    = azurerm_key_vault.secrets["jira_read"].vault_uri
    PROPOSAL_CONTAINER     = azurerm_cosmosdb_sql_container.containers["defect_proposals"].name
    EVENT_CONTAINER        = azurerm_cosmosdb_sql_container.containers["defect_events"].name
    DEFECT_AI_REQUIRED     = tostring(var.defect_ai_required)
    AZURE_OPENAI_ENDPOINT  = var.azure_openai_endpoint
    AZURE_OPENAI_DEPLOYMENT = var.azure_openai_deployment
  })
  tags = var.tags
}

module "jira_executor" {
  source                                = "./modules/function_app"
  name                                  = "${local.prefix}-jira-executor-${local.suffix}"
  location                              = local.location
  resource_group_name                   = local.rg_name
  service_plan_id                       = azurerm_service_plan.consumption.id
  storage_account_name                  = azurerm_storage_account.functions.name
  storage_account_access_key            = azurerm_storage_account.functions.primary_access_key
  application_insights_connection_string = azurerm_application_insights.monitoring.connection_string
  app_settings = merge(local.common_env, local.bus_env, {
    ACTION_QUEUE_NAME    = azurerm_servicebus_queue.queues["defect_actions"].name
    JIRA_WRITE_VAULT_URL = azurerm_key_vault.secrets["jira_write"].vault_uri
    AUTH_CONTAINER       = azurerm_cosmosdb_sql_container.containers["defect_authorization"].name
    PROPOSAL_CONTAINER   = azurerm_cosmosdb_sql_container.containers["defect_proposals"].name
  })
  tags = var.tags
}

# Service Bus data-plane RBAC (no shared access keys in app settings).
locals {
  sb_permissions = {
    ingress_asset   = { principal = module.ingress.principal_id, queue = "asset_requests", role = "Azure Service Bus Data Sender" }
    ingress_defect  = { principal = module.ingress.principal_id, queue = "defect_requests", role = "Azure Service Bus Data Sender" }
    ingress_actions = { principal = module.ingress.principal_id, queue = "defect_actions", role = "Azure Service Bus Data Sender" }
    asset_receiver  = { principal = module.asset_worker.principal_id, queue = "asset_requests", role = "Azure Service Bus Data Receiver" }
    defect_receiver = { principal = module.defect_worker.principal_id, queue = "defect_requests", role = "Azure Service Bus Data Receiver" }
    exec_receiver   = { principal = module.jira_executor.principal_id, queue = "defect_actions", role = "Azure Service Bus Data Receiver" }
  }
}
resource "azurerm_role_assignment" "servicebus_functions" {
  for_each             = local.sb_permissions
  scope                = azurerm_servicebus_queue.queues[each.value.queue].id
  role_definition_name = each.value.role
  principal_id         = each.value.principal
}
# Development user can invoke and consume queues during local testing.
resource "azurerm_role_assignment" "local_developer_servicebus" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Cosmos DB native data-plane RBAC scoped to exact containers.
locals {
  cosmos_permissions = {
    ingress_authorization = { principal = module.ingress.principal_id, container = "defect_authorization", role = "reader" }
    asset_sessions        = { principal = module.asset_worker.principal_id, container = "asset_sessions", role = "writer" }
    asset_events          = { principal = module.asset_worker.principal_id, container = "asset_events", role = "writer" }
    defect_proposals      = { principal = module.defect_worker.principal_id, container = "defect_proposals", role = "writer" }
    defect_events         = { principal = module.defect_worker.principal_id, container = "defect_events", role = "writer" }
    executor_authorization = { principal = module.jira_executor.principal_id, container = "defect_authorization", role = "reader" }
    executor_proposals    = { principal = module.jira_executor.principal_id, container = "defect_proposals", role = "writer" }
  }
  cosmos_reader_role = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001"
  cosmos_writer_role = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
}
resource "azurerm_cosmosdb_sql_role_assignment" "data" {
  for_each            = local.cosmos_permissions
  resource_group_name = local.rg_name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = each.value.role == "reader" ? local.cosmos_reader_role : local.cosmos_writer_role
  principal_id        = each.value.principal
  scope               = azurerm_cosmosdb_sql_container.containers[each.value.container].id
}

resource "azurerm_role_assignment" "ingress_slack_secret" {
  scope                = azurerm_key_vault.secrets["slack"].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.ingress.principal_id
}
resource "azurerm_role_assignment" "worker_jira_read_secret" {
  scope                = azurerm_key_vault.secrets["jira_read"].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.defect_worker.principal_id
}
resource "azurerm_role_assignment" "executor_jira_write_secret" {
  scope                = azurerm_key_vault.secrets["jira_write"].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.jira_executor.principal_id
}

# Local developer's identity can run all four Functions against the development database.
# Deployed Function Apps still have container-scoped permissions.
resource "azurerm_cosmosdb_sql_role_assignment" "local_developer" {
  resource_group_name = local.rg_name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = local.cosmos_writer_role
  principal_id        = data.azurerm_client_config.current.object_id
  scope               = azurerm_cosmosdb_account.main.id
}
