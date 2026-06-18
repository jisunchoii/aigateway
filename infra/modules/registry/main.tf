variable "suffix" {
  type        = string
  description = "Random per-deployment suffix for the globally-unique ACR name."
}
variable "name_prefix" {
  type        = string
  default     = "llmgw"
  description = "Workload prefix for the ACR name (alphanumeric only). Defaults to llmgw so the existing live registry name (acrllmgw<suffix>) is unchanged; root passes var.prefix so fresh deploys get acr<prefix><suffix>."
}
variable "resource_group_name" {
  type        = string
  description = "Resource group to create the registry in."
}
variable "location" {
  type        = string
  description = "Azure region."
}
variable "tags" {
  type        = map(string)
  description = "Tags applied to the registry."
}

resource "azurerm_container_registry" "acr" {
  # 5-50 alphanumeric, globally unique. name_prefix sanitized to alphanumerics.
  name                = "acr${replace(var.name_prefix, "/[^a-z0-9]/", "")}${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false # passwordless: pull via managed identity (AcrPull)
  tags                = var.tags
}

output "id" {
  description = "Resource ID of the container registry."
  value       = azurerm_container_registry.acr.id
}
output "login_server" {
  description = "Login server hostname (e.g. acrllmgwxxxxxx.azurecr.io) for image references."
  value       = azurerm_container_registry.acr.login_server
}
output "name" {
  description = "Registry name (used by az acr build)."
  value       = azurerm_container_registry.acr.name
}
