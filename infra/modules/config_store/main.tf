variable "name_suffix" {
  type        = string
  description = "Naming suffix (workload-env-region) used in deterministic resource names such as the private endpoint."
}
variable "suffix" {
  type        = string
  description = "Six-character random alphanumeric suffix appended to the Cosmos DB account name for global uniqueness."
}
variable "resource_group_name" {
  type        = string
  description = "Name of the resource group where the Cosmos DB account and its private endpoint are created."
}
variable "location" {
  type        = string
  description = "Azure region for all resources in this module."
}
variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources."
}
variable "pe_subnet_id" {
  type        = string
  description = "Resource ID of the private endpoint subnet where the Cosmos DB private endpoint NIC is placed."
}
variable "dns_zone_id" {
  type        = string
  description = "Resource ID of the privatelink.documents.azure.com private DNS zone used for the Cosmos DB A-record."
}
variable "reader_principal_ids" {
  type        = map(string)
  default     = {}
  description = "Static label -> principal object ID granted Cosmos DB data-plane read-only via the built-in Data Reader role (e.g. { config_sync_worker = <oid> }). Keys must be statically known so for_each can plan before the identities exist. Seed/config writes are performed out-of-band by an operator."
}
variable "writer_principal_ids" {
  type        = map(string)
  default     = {}
  description = "Static label -> principal object ID granted Cosmos DB data-plane read/write via the built-in Data Contributor role (e.g. { admin_ui = <oid> }). Keys must be statically known so for_each can plan before the identities exist. Used by the Admin UI BFF, which gets Data Contributor on BOTH the team_subscription_map and config containers (subscription mappings + per-team config docs)."
}
variable "config_writer_principal_ids" {
  type        = map(string)
  default     = {}
  description = "Static label -> principal object ID granted Cosmos DB data-plane read/write on ONLY the `config` container (built-in Data Contributor). For the config-sync worker, which writes active_downgrade state back to team_config docs (Phase 4) but must not write team_subscription_map."
}

resource "azurerm_cosmosdb_account" "config" {
  name                          = "cosmos-${var.name_suffix}-${var.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  offer_type                    = "Standard"
  kind                          = "GlobalDocumentDB"
  local_authentication_disabled = true
  public_network_access_enabled = false
  automatic_failover_enabled    = false
  tags                          = var.tags

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "config" {
  name                = "gateway"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.config.name
}

resource "azurerm_cosmosdb_sql_container" "config" {
  name                = "config"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.config.name
  database_name       = azurerm_cosmosdb_sql_database.config.name
  partition_key_paths = ["/id"]
}

resource "azurerm_cosmosdb_sql_container" "team_subscription_map" {
  name                = "team_subscription_map"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.config.name
  database_name       = azurerm_cosmosdb_sql_database.config.name
  partition_key_paths = ["/id"]
}

resource "azurerm_private_endpoint" "cosmos" {
  name                = "pe-cosmos-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-cosmos"
    private_connection_resource_id = azurerm_cosmosdb_account.config.id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "cosmos-dns"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

# Data-plane RBAC (separate from ARM RBAC).
# Built-in "Cosmos DB Built-in Data Reader" role definition id: ...0001
# Reader principals (e.g. the config-sync worker) read any container in the account. The worker
# ALSO writes the `config` container (active_downgrade, Phase 4) — see config_data_writer below.
# Scoped to the Cosmos account so the principal can read any container within it.
resource "azurerm_cosmosdb_sql_role_assignment" "data_reader" {
  for_each            = var.reader_principal_ids
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.config.name
  role_definition_id  = "${azurerm_cosmosdb_account.config.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001"
  principal_id        = each.value
  scope               = azurerm_cosmosdb_account.config.id
}

# Data-plane WRITE (Data Contributor, role def ...0002) for the Admin UI BFF.
# Separate from ARM RBAC; lets the BFF upsert/delete team<->subscription mapping docs.
# Container-scoped (not account-wide). The BFF also writes the `config` container — see
# data_writer_config below; together these are the two containers the BFF legitimately writes.
resource "azurerm_cosmosdb_sql_role_assignment" "data_writer" {
  for_each            = var.writer_principal_ids
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.config.name
  role_definition_id  = "${azurerm_cosmosdb_account.config.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = each.value
  scope               = "${azurerm_cosmosdb_account.config.id}/dbs/${azurerm_cosmosdb_sql_database.config.name}/colls/${azurerm_cosmosdb_sql_container.team_subscription_map.name}"
}

# The Admin UI BFF also writes per-team config docs (Phase 3c) into the `config` container.
# Container-scoped Data Contributor (paired with data_writer above). The BFF writes exactly two
# containers — team_subscription_map and config — and nothing else in the account; any future
# container is NOT writable by the BFF unless a matching assignment is added here.
resource "azurerm_cosmosdb_sql_role_assignment" "data_writer_config" {
  for_each            = var.writer_principal_ids
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.config.name
  role_definition_id  = "${azurerm_cosmosdb_account.config.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = each.value
  scope               = "${azurerm_cosmosdb_account.config.id}/dbs/${azurerm_cosmosdb_sql_database.config.name}/colls/${azurerm_cosmosdb_sql_container.config.name}"
}

# The config-sync worker writes active_downgrade back into team_config docs (Phase 4). Data
# Contributor scoped to ONLY the `config` container — the worker must not write
# team_subscription_map (that's the BFF's). Separate from writer_principal_ids so the worker
# gets exactly one container's worth of write, not the BFF's two.
resource "azurerm_cosmosdb_sql_role_assignment" "config_data_writer" {
  for_each            = var.config_writer_principal_ids
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.config.name
  role_definition_id  = "${azurerm_cosmosdb_account.config.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = each.value
  scope               = "${azurerm_cosmosdb_account.config.id}/dbs/${azurerm_cosmosdb_sql_database.config.name}/colls/${azurerm_cosmosdb_sql_container.config.name}"
}

output "id" {
  description = "Resource ID of the Cosmos DB account."
  value       = azurerm_cosmosdb_account.config.id
}
output "endpoint" {
  description = "Document endpoint URL (https://<account>.documents.azure.com:443/) used by SDK clients."
  value       = azurerm_cosmosdb_account.config.endpoint
}
output "account_name" {
  description = "Name of the Cosmos DB account."
  value       = azurerm_cosmosdb_account.config.name
}
output "database_name" {
  description = "Name of the SQL database created inside the Cosmos DB account (gateway)."
  value       = azurerm_cosmosdb_sql_database.config.name
}
output "container_name" {
  description = "Name of the SQL container created inside the gateway database (config)."
  value       = azurerm_cosmosdb_sql_container.config.name
}
output "map_container_name" {
  description = "Name of the team<->subscription mapping container (team_subscription_map)."
  value       = azurerm_cosmosdb_sql_container.team_subscription_map.name
}
