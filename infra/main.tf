data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = var.location
  tags     = local.tags
}

module "network" {
  source              = "./modules/network"
  name_suffix         = local.name_suffix
  suffix              = local.sfx
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
  enable_jumpbox      = var.enable_jumpbox
  apim_public         = var.apim_public
}

module "identity" {
  source              = "./modules/identity"
  name_suffix         = local.name_suffix
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
}

module "keyvault" {
  source              = "./modules/keyvault"
  name_suffix         = local.name_suffix
  suffix              = local.sfx
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
  pe_subnet_id        = module.network.pe_subnet_id
  dns_zone_id         = module.network.dns_zone_ids["keyvault"]
}

module "observability" {
  source              = "./modules/observability"
  name_suffix         = local.name_suffix
  resource_group_name = azurerm_resource_group.rg.name
  resource_group_id   = azurerm_resource_group.rg.id
  location            = var.location
  tags                = local.tags
  budget_amount       = var.monthly_budget_amount
  budget_alert_email  = var.budget_alert_email
  budget_start_date   = var.budget_start_date
}

removed {
  from = module.openai

  lifecycle {
    destroy = false
  }
}

moved {
  from = azurerm_api_management_named_value.codexproxy_key
  to   = module.apim.azurerm_api_management_named_value.codexproxy_key
}

module "foundry" {
  source              = "./modules/foundry"
  name_suffix         = local.name_suffix
  suffix              = local.sfx
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
  pe_subnet_id        = module.network.pe_subnet_id
  dns_zone_ids = [
    module.network.dns_zone_ids["cognitiveservices"],
    module.network.dns_zone_ids["aiservices"],
    module.network.dns_zone_ids["openai"],
  ]
  deployments                   = var.model_deployments
  account_name                  = var.foundry_account_name
  project_name                  = var.foundry_project_name
  public_network_access_enabled = var.foundry_public_network_access_enabled
  reuse_existing                = var.reuse_foundry
  existing_account_name         = var.existing_foundry_name
  existing_account_rg           = var.existing_foundry_rg
}

module "jumpbox" {
  source              = "./modules/jumpbox"
  enabled             = var.enable_jumpbox
  name_suffix         = local.name_suffix
  suffix              = local.sfx
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
  bastion_subnet_id   = module.network.bastion_subnet_id
  jumpbox_subnet_id   = module.network.jumpbox_subnet_id
  admin_password      = var.jumpbox_admin_password
  vm_size             = var.jumpbox_vm_size
  # Seed Cosmos config/pricing docs from the VM MI; wait for the data-plane role assignment.
  cosmos_endpoint         = module.config_store.endpoint
  seed_role_assignment_id = try(module.config_store.config_writer_role_assignment_ids["jumpbox"], null)
}

module "apim" {
  source                        = "./modules/apim"
  depends_on                    = [module.network, module.foundry]
  name_suffix                   = local.name_suffix
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = var.location
  tags                          = local.tags
  sku_name                      = var.apim_sku_name
  publisher_name                = var.apim_publisher_name
  publisher_email               = var.apim_publisher_email
  apim_subnet_id                = module.network.apim_subnet_id
  public_ip_id                  = module.network.apim_public_ip_id
  public                        = var.apim_public
  model_account_id              = module.foundry.id
  model_openai_v1_base          = module.foundry.endpoint_openai_v1
  policy_template_path          = "${path.root}/../policies/inference-pipeline.xml.tftpl"
  appinsights_id                = module.observability.appi_id
  appinsights_connection_string = module.observability.appi_connection_string
  tokens_per_minute             = var.tokens_per_minute
  model_tokens_per_minute       = local.model_tokens_per_minute
  token_quota                   = var.token_quota
  token_quota_period            = var.token_quota_period
  allowed_model_names           = local.allowed_models
  rate_tiers                    = var.rate_tiers
  client_auth_mode              = var.client_auth_mode
  entra_tenant_id               = var.entra_tenant_id
  entra_api_audience            = var.entra_api_audience
  entra_team_claim              = var.entra_team_claim
  codexproxy_enabled            = local.codexproxy_enabled
  codexproxy_base_url           = local.codexproxy_enabled ? "https://${module.control_plane.codexproxy_fqdn}" : ""
  codexproxy_key                = local.codexproxy_key
  searchmcp_enabled             = local.searchmcp_enabled
  searchmcp_base_url            = local.searchmcp_enabled ? "https://${module.control_plane.searchmcp_fqdn}" : ""
}

module "config_store" {
  source               = "./modules/config_store"
  name_suffix          = local.name_suffix
  suffix               = local.sfx
  resource_group_name  = azurerm_resource_group.rg.name
  location             = var.location
  tags                 = local.tags
  pe_subnet_id         = module.network.pe_subnet_id
  dns_zone_id          = module.network.dns_zone_ids["cosmos"]
  reader_principal_ids = { config_sync_worker = module.identity.worker_principal_id }
  writer_principal_ids = { admin_ui = module.identity.cp_write_principal_id }
  # config-sync worker writes active_downgrade; the jumpbox MI (when enabled) gets the same
  # config-container write so operators can run the seed scripts (id=global, id=pricing) from it.
  config_writer_principal_ids = merge(
    { config_sync_worker = module.identity.worker_principal_id },
    var.enable_jumpbox ? { jumpbox = module.jumpbox.vm_principal_id } : {}
  )
}

module "registry" {
  source              = "./modules/registry"
  suffix              = local.sfx
  name_prefix         = var.prefix
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
}

module "control_plane" {
  source                = "./modules/control_plane"
  name_suffix           = local.name_suffix
  resource_group_name   = azurerm_resource_group.rg.name
  location              = var.location
  tags                  = local.tags
  infra_subnet_id       = module.network.aca_subnet_id
  law_id                = module.observability.law_id
  acr_id                = module.registry.id
  acr_login_server      = module.registry.login_server
  apim_id               = module.apim.id
  worker_identity_id    = module.identity.worker_id
  worker_principal_id   = module.identity.worker_principal_id
  worker_client_id      = module.identity.worker_client_id
  worker_image          = var.worker_image
  config_sync_cron      = var.config_sync_cron
  cosmos_endpoint       = module.config_store.endpoint
  cosmos_database       = module.config_store.database_name
  cosmos_container      = module.config_store.container_name
  subscription_id       = data.azurerm_client_config.current.subscription_id
  apim_rg               = azurerm_resource_group.rg.name
  apim_name             = module.apim.name
  vnet_id               = module.network.vnet_id
  admin_ui_image        = var.admin_ui_image
  admin_ui_public       = var.admin_ui_public
  admin_ui_identity_id  = module.identity.cp_write_id
  admin_ui_principal_id = module.identity.cp_write_principal_id
  admin_ui_client_id    = module.identity.cp_write_client_id
  entra_tenant_id       = var.entra_tenant_id
  bff_api_audience      = var.bff_api_audience
  spa_client_id         = var.spa_client_id
  admin_group_object_id = var.admin_group_object_id
  cosmos_map_container  = module.config_store.map_container_name
  rate_tiers_json       = jsonencode(var.rate_tiers)
  # The final catalog follows canonical deployments; config-sync still owns APIM runtime named values.
  alias_models_json          = jsonencode({ for model in local.allowed_models : model => model })
  log_analytics_workspace_id = module.observability.law_customer_id
  codexproxy_image           = var.codexproxy_image
  searchmcp_image            = var.searchmcp_image
  codexproxy_identity_id     = module.identity.codexproxy_id
  codexproxy_principal_id    = module.identity.codexproxy_principal_id
  codexproxy_client_id       = module.identity.codexproxy_client_id
  codexproxy_key             = local.codexproxy_key
  codexproxy_project_base    = module.foundry.project_responses_base
}

# The Admin UI BFF (cp_write identity) reads token metrics + request logs from Log Analytics
# for the Dashboard ① / Monitoring ⑦ pages. Log Analytics Reader on the workspace is read-only.
# Gated on the admin UI being deployed, matching the sibling admin_ui_apim / admin_ui_acr_pull grants.
resource "azurerm_role_assignment" "admin_ui_log_reader" {
  count                = var.admin_ui_image != "" ? 1 : 0
  scope                = module.observability.law_id
  role_definition_name = "Log Analytics Reader"
  principal_id         = module.identity.cp_write_principal_id
}

# The config-sync worker reads daily token usage from Log Analytics to evaluate budgets and set
# active_downgrade (Phase 4). Log Analytics Reader on the workspace is read-only. Gated on the
# worker being deployed, matching the sibling worker_acr_pull / worker_apim grants.
resource "azurerm_role_assignment" "worker_log_reader" {
  count                = var.worker_image != "" ? 1 : 0
  scope                = module.observability.law_id
  role_definition_name = "Log Analytics Reader"
  principal_id         = module.identity.worker_principal_id
}

resource "random_password" "codexproxy_key" {
  count   = local.codexproxy_enabled || local.searchmcp_enabled ? 1 : 0
  length  = 48
  special = false
}

locals {
  codexproxy_key = local.codexproxy_enabled || local.searchmcp_enabled ? "sk-${random_password.codexproxy_key[0].result}" : ""
}

resource "azurerm_role_assignment" "codexproxy_to_project_account" {
  count                = local.codexproxy_enabled || local.searchmcp_enabled ? 1 : 0
  scope                = module.foundry.id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.identity.codexproxy_principal_id
}
