variable "name_suffix" {
  type        = string
  description = "Naming suffix (workload-env-region) used in resource names that need deterministic uniqueness."
}
variable "suffix" {
  type        = string
  description = "Six-character random alphanumeric suffix used in globally-unique names such as the Key Vault name."
}
variable "resource_group_name" {
  type        = string
  description = "Name of the resource group where the Key Vault and its private endpoint are created."
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
  description = "Resource ID of the private endpoint subnet where the Key Vault private endpoint NIC is placed."
}
variable "dns_zone_id" {
  type        = string
  description = "Resource ID of the privatelink.vaultcore.azure.net private DNS zone used for the vault A-record."
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                          = "kv-${var.suffix}" # <=24 chars; "kv-" + 6 = 9 chars, globally unique via suffix
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = false
  tags                          = var.tags
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-kv-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-kv"
    private_connection_resource_id = azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv-dns"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

output "id" {
  description = "Resource ID of the Key Vault."
  value       = azurerm_key_vault.kv.id
}
output "name" {
  description = "Name of the Key Vault (used to construct Key Vault references in App Settings)."
  value       = azurerm_key_vault.kv.name
}
output "uri" {
  description = "Vault URI (https://<name>.vault.azure.net/) used by SDK clients and Key Vault references."
  value       = azurerm_key_vault.kv.vault_uri
}
