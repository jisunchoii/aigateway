variable "name_suffix" {
  type        = string
  description = "Naming suffix (workload-env-region) used in deterministic resource names."
}
variable "suffix" {
  type        = string
  description = "Six-character random alphanumeric suffix used for the globally-unique custom subdomain."
}
variable "resource_group_name" {
  type        = string
  description = "Name of the resource group where the Azure OpenAI account and its private endpoint are created."
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
  description = "Resource ID of the private endpoint subnet where the OpenAI private endpoint NIC is placed."
}
variable "dns_zone_id" {
  type        = string
  description = "Resource ID of the privatelink.openai.azure.com private DNS zone used for the OpenAI A-record."
}
variable "deployments" {
  type = map(object({
    model_name    = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  description = "Map of model deployments to create on the Azure OpenAI account. Keys become deployment names."
}

resource "azurerm_cognitive_account" "openai" {
  name                          = "oai-${var.name_suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  kind                          = "OpenAI"
  sku_name                      = "S0"
  custom_subdomain_name         = "oai-${var.suffix}"
  local_auth_enabled            = false
  public_network_access_enabled = false
  tags                          = var.tags

  network_acls {
    default_action = "Deny"
  }
}

resource "azurerm_cognitive_deployment" "models" {
  for_each             = var.deployments
  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = each.value.model_name
    version = each.value.model_version
  }

  sku {
    name     = each.value.sku_name
    capacity = each.value.capacity
  }
}

resource "azurerm_private_endpoint" "openai" {
  name                = "pe-oai-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-oai"
    private_connection_resource_id = azurerm_cognitive_account.openai.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "oai-dns"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

output "id" {
  description = "Resource ID of the Azure OpenAI cognitive account."
  value       = azurerm_cognitive_account.openai.id
}
output "name" {
  description = "Name of the Azure OpenAI cognitive account."
  value       = azurerm_cognitive_account.openai.name
}
output "endpoint" {
  description = "HTTPS endpoint URL of the Azure OpenAI account (e.g. https://oai-<suffix>.openai.azure.com/)."
  value       = azurerm_cognitive_account.openai.endpoint
}
output "deployment_names" {
  description = "List of model deployment names created on the Azure OpenAI account."
  value       = [for k, d in azurerm_cognitive_deployment.models : k]
}
