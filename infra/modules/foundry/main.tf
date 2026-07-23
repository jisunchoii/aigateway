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
  description = "Supported model deployments. Reuse mode expects these deployments to exist and does not manage them."
}

variable "reuse_existing" {
  type        = bool
  default     = false
  description = "Read an existing AIServices account and skip model deployment management. Terraform creates and manages the project unless reuse_existing_project is true, and continues to manage the gateway PE and RBAC."
}

variable "reuse_existing_project" {
  type        = bool
  default     = false
  description = "Read the existing Foundry project without managing its lifecycle. Use only with reuse_existing = true."
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
  description = "Name of the project-enabled AIServices account created by Terraform. Defaults to aisproj- followed by the generated random suffix."
}

variable "project_name" {
  type        = string
  default     = "gatewayproj"
  description = "Foundry project used by Responses clients. Set the exact existing project name when reuse_existing_project is true."
}

variable "public_network_access_enabled" {
  type        = bool
  default     = false
  description = "Temporary private-endpoint validation option. Keep false for normal deployments."
}

# Reuse an existing AIServices account instead of creating one.
data "azurerm_cognitive_account" "existing" {
  count               = var.reuse_existing ? 1 : 0
  name                = var.existing_account_name
  resource_group_name = var.existing_account_rg

  lifecycle {
    postcondition {
      condition     = self.local_auth_enabled == false
      error_message = "Reused AIServices account has key auth enabled. Disable it before deploy: az resource update --ids <account-id> --set properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled (see GitBook 04)."
    }

    postcondition {
      condition     = self.project_management_enabled == true
      error_message = "Reused AIServices account must already have project management enabled before this module can create or attach the Foundry project."
    }

    postcondition {
      condition     = self.public_network_access_enabled == false
      error_message = "Reused AIServices account must already have public network access disabled before this module can attach the private-only gateway topology."
    }
  }
}

data "azapi_resource" "existing_project" {
  count = var.reuse_existing_project ? 1 : 0

  type      = "Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview"
  name      = var.project_name
  parent_id = local.account_id

  lifecycle {
    precondition {
      condition     = var.reuse_existing
      error_message = "reuse_existing_project requires reuse_existing = true."
    }
  }
}

locals {
  managed_account_name     = var.account_name != "" ? var.account_name : "aisproj-${var.suffix}"
  reused_endpoint          = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].endpoint : null
  reused_endpoint_host     = var.reuse_existing ? trimsuffix(trimprefix(trimprefix(local.reused_endpoint, "https://"), "http://"), "/") : null
  account_custom_subdomain = var.reuse_existing ? split(".", local.reused_endpoint_host)[0] : local.managed_account_name
  account_id               = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].id : azapi_resource.project_account[0].id
  account_name             = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].name : local.managed_account_name
  account_endpoint         = var.reuse_existing ? local.reused_endpoint : "https://${local.managed_account_name}.cognitiveservices.azure.com/"
  account_openai_host      = "https://${local.account_custom_subdomain}.openai.azure.com"
  account_openai_v1        = "${local.account_openai_host}/openai/v1"
  project_responses_base   = "https://${local.account_custom_subdomain}.services.ai.azure.com/api/projects/${var.project_name}/openai/v1"
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
  type      = "Microsoft.CognitiveServices/accounts@2025-10-01-preview"
  name      = local.managed_account_name
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  location  = var.location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku  = { name = "S0" }
    properties = {
      allowProjectManagement = true
      associatedProjects     = [var.project_name]
      customSubDomainName    = local.managed_account_name
      defaultProject         = var.project_name
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
  count     = var.reuse_existing_project ? 0 : 1
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview"
  name      = var.project_name
  parent_id = local.account_id
  location  = var.location

  identity {
    type = "SystemAssigned"
  }

  body = {
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
  description = "AIServices account resource ID used by the gateway."
}

output "name" {
  value       = local.account_name
  description = "AIServices account name used by the gateway."
}

output "endpoint" {
  value       = local.account_endpoint
  description = "AIServices control endpoint used by the gateway."
}

output "endpoint_openai_v1" {
  value       = local.account_openai_v1
  description = "OpenAI/v1 inference base used by the gateway."
}

output "endpoint_openai_host" {
  value       = local.account_openai_host
  description = "OpenAI host used by the gateway."
}

output "deployment_names" {
  value       = sort(keys(var.deployments))
  description = "Configured deployment names; in reuse mode these describe the expected existing catalog."
}

output "project_account_id" {
  value       = local.account_id
  description = "Compatibility alias for the gateway AIServices account ID."
}

output "project_responses_base" {
  value       = local.project_responses_base
  description = "Foundry project OpenAI/v1 base."
}
