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
  description = "Name of the resource group where the AIServices account and its private endpoint are created."
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
  description = "Resource ID of the private endpoint subnet where the AIServices private endpoint NIC is placed."
}
variable "dns_zone_ids" {
  type        = list(string)
  description = "Private DNS zone IDs for the AIServices PE (cognitiveservices + services.ai + openai)."
}
variable "deployments" {
  type = map(object({
    model_name    = string
    model_format  = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  description = "Foundry OSS/partner model deployments (PAYG GlobalStandard). Keys become deployment names (= client-facing aliases)."
}

resource "azurerm_cognitive_account" "foundry" {
  name                          = "ais-${var.name_suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = "ais-${var.suffix}"
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
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = each.value.model_format
    name    = each.value.model_name
    version = each.value.model_version
  }

  sku {
    name     = each.value.sku_name
    capacity = each.value.capacity
  }
}

resource "azurerm_private_endpoint" "foundry" {
  name                = "pe-ais-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-ais"
    private_connection_resource_id = azurerm_cognitive_account.foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "ais-dns"
    private_dns_zone_ids = var.dns_zone_ids
  }
}

output "id" {
  description = "Resource ID of the AIServices (Foundry) cognitive account."
  value       = azurerm_cognitive_account.foundry.id
}
output "name" {
  description = "Name of the AIServices (Foundry) cognitive account."
  value       = azurerm_cognitive_account.foundry.name
}
output "endpoint" {
  description = "AIServices account control endpoint (https://ais-<suffix>.cognitiveservices.azure.com/)."
  value       = azurerm_cognitive_account.foundry.endpoint
}
output "endpoint_openai_v1" {
  description = <<-EOT
    GA OpenAI/v1 inference base for the AIServices account, e.g.
    https://ais-<suffix>.openai.azure.com/openai/v1. Per Microsoft Learn the Azure AI Model
    Inference (/models) path's beta SDK is deprecated (retires 2026-08-26); OpenAI/v1 is the GA
    route and accepts non-OpenAI (OSS/partner) deployments with the deployment name in the body
    "model" field. APIM's foundry API uses this as its service_url.
  EOT
  value       = "${trimsuffix(replace(azurerm_cognitive_account.foundry.endpoint, ".cognitiveservices.azure.com", ".openai.azure.com"), "/")}/openai/v1"
}
output "endpoint_openai_host" {
  description = "AIServices account openai.azure.com host base (no path), e.g. https://ais-<suffix>.openai.azure.com. Used as the cross-backend set-backend-service base when a downgrade targets an OSS model from the /openai API."
  value       = trimsuffix(replace(azurerm_cognitive_account.foundry.endpoint, ".cognitiveservices.azure.com", ".openai.azure.com"), "/")
}
output "deployment_names" {
  description = "List of model deployment names created on the AIServices account."
  value       = [for k, d in azurerm_cognitive_deployment.models : k]
}
