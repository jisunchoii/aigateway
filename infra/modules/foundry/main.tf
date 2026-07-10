terraform {
  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

data "azurerm_client_config" "current" {}

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
  description = "Unified deployment catalog for the canonical project-enabled AIServices account."
}

variable "reuse_existing" {
  type        = bool
  default     = false
  description = "When true, read an existing project-enabled AIServices account via data source instead of creating it; do not create model deployments. The project and PE are still managed against the referenced account."
}

variable "existing_account_name" {
  type        = string
  default     = ""
  description = "Name of the existing AIServices account (required when reuse_existing = true)."
}

variable "existing_account_rg" {
  type        = string
  default     = ""
  description = "Resource group of the existing AIServices account (required when reuse_existing = true)."
}

variable "account_name" {
  type        = string
  default     = ""
  description = "Managed project-enabled AIServices account name. Defaults to ais- followed by the generated random suffix."
}

variable "project_name" {
  type        = string
  default     = "codexproj"
  description = "Child Foundry project used by Responses clients."
}

variable "public_network_access_enabled" {
  type        = bool
  default     = false
  description = "Migration escape hatch. Keep false for fresh/final deployments; set true only while validating a newly attached private endpoint."
}

# Brownfield: reference an existing AIServices account instead of creating one.
data "azurerm_cognitive_account" "existing" {
  count               = var.reuse_existing ? 1 : 0
  name                = var.existing_account_name
  resource_group_name = var.existing_account_rg

  lifecycle {
    postcondition {
      condition     = self.local_auth_enabled == false
      error_message = "Reused AIServices account has key auth enabled. Disable it before deploy: az resource update --ids <account-id> --set properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled (see GitBook 04)."
    }
  }
}

locals {
  managed_account_name = var.account_name != "" ? var.account_name : "ais-${var.suffix}"
  account_id           = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].id : azapi_resource.project_account[0].id
  account_name         = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].name : local.managed_account_name
}

removed {
  from = azurerm_cognitive_account.foundry

  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_cognitive_deployment.models

  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_private_endpoint.foundry

  lifecycle {
    destroy = false
  }
}

resource "azapi_resource" "project_account" {
  count     = var.reuse_existing ? 0 : 1
  type      = "Microsoft.CognitiveServices/accounts@2025-04-01-preview"
  name      = local.managed_account_name
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  location  = var.location
  tags      = var.tags

  body = {
    kind     = "AIServices"
    sku      = { name = "S0" }
    identity = { type = "SystemAssigned" }
    properties = {
      allowProjectManagement = true
      customSubDomainName    = local.managed_account_name
      disableLocalAuth       = true
      publicNetworkAccess    = var.public_network_access_enabled ? "Enabled" : "Disabled"
      networkAcls = {
        defaultAction = var.public_network_access_enabled ? "Allow" : "Deny"
      }
    }
  }
  response_export_values = ["properties.endpoints", "properties.endpoint"]
}

resource "azapi_resource" "project" {
  count     = 1
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = var.project_name
  parent_id = local.account_id
  location  = var.location

  body = {
    identity   = { type = "SystemAssigned" }
    properties = {}
  }
}

resource "azurerm_cognitive_deployment" "project_models" {
  for_each             = var.reuse_existing ? {} : var.deployments
  name                 = each.key
  cognitive_account_id = azapi_resource.project_account[0].id

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

resource "time_sleep" "foundry_settle" {
  depends_on      = [azapi_resource.project_account]
  create_duration = "60s"

  triggers = {
    account_id = local.account_id
  }
}

resource "azurerm_private_endpoint" "project_account" {
  name                = "pe-foundry-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  depends_on = [time_sleep.foundry_settle]

  private_service_connection {
    name                           = "psc-foundry"
    private_connection_resource_id = local.account_id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "foundry-dns"
    private_dns_zone_ids = var.dns_zone_ids
  }
}

output "id" {
  value       = local.account_id
  description = "Canonical project-enabled AIServices account resource ID."
}

output "name" {
  value       = local.account_name
  description = "Canonical project-enabled AIServices account name."
}

output "endpoint" {
  value       = "https://${local.account_name}.cognitiveservices.azure.com/"
  description = "Canonical AIServices control endpoint."
}

output "endpoint_openai_v1" {
  value       = "https://${local.account_name}.openai.azure.com/openai/v1"
  description = "Canonical OpenAI/v1 inference base."
}

output "endpoint_openai_host" {
  value       = "https://${local.account_name}.openai.azure.com"
  description = "Canonical OpenAI host."
}

output "deployment_names" {
  value       = sort(keys(var.deployments))
  description = "Configured deployment names; in reuse mode these describe the expected existing catalog."
}

output "project_account_id" {
  value       = local.account_id
  description = "Compatibility alias for the canonical account ID."
}

output "project_responses_base" {
  value       = "https://${local.account_name}.services.ai.azure.com/api/projects/${var.project_name}/openai/v1"
  description = "Canonical project OpenAI/v1 base used by the Codex proxy."
}
