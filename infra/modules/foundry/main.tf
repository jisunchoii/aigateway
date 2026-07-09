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
  description = "Foundry OSS/partner model deployments (PAYG GlobalStandard). Keys become deployment names (= client-facing aliases)."
}
variable "reuse_existing" {
  type        = bool
  default     = false
  description = "When true, read an existing AIServices account via data source instead of creating it; do not create model deployments. PE + RBAC are still created against the referenced account."
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
variable "enable_project_account" {
  type        = bool
  default     = false
  description = "Create a NEW project-enabled AIServices account (allowProjectManagement=true) + one project for the Codex proxy sidecar backend. Fireworks models need the project route for Responses."
}
variable "project_account_name" {
  type        = string
  default     = ""
  description = "Name of the project-enabled AIServices account. Defaults to aisproj-<suffix> when empty."
}

resource "azurerm_cognitive_account" "foundry" {
  count                         = var.reuse_existing ? 0 : 1
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

# Brownfield: reference an existing AIServices account instead of creating one.
data "azurerm_cognitive_account" "existing" {
  count               = var.reuse_existing ? 1 : 0
  name                = var.existing_account_name
  resource_group_name = var.existing_account_rg

  lifecycle {
    postcondition {
      # Gateway standard: the reused account must have key auth disabled (passwordless).
      # If azurerm omits local_auth_enabled on this data source for the pinned provider
      # version, remove this postcondition and rely on the az pre-check in GitBook 04.
      condition     = self.local_auth_enabled == false
      error_message = "Reused AIServices account has key auth enabled. Disable it before deploy: az resource update --ids <account-id> --set properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled (see GitBook 04)."
    }
  }
}

locals {
  account_id       = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].id : azurerm_cognitive_account.foundry[0].id
  account_name     = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].name : azurerm_cognitive_account.foundry[0].name
  account_endpoint = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].endpoint : azurerm_cognitive_account.foundry[0].endpoint
}

resource "azurerm_cognitive_deployment" "models" {
  for_each             = var.reuse_existing ? {} : var.deployments
  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.foundry[0].id

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

# The cognitive account can still report provisioningState="Accepted" for a short
# window after create returns, which makes a parallel private-endpoint create fail with
# 400 AccountProvisioningStateInvalid. Wait for the account to settle before attaching it.
resource "time_sleep" "foundry_settle" {
  count           = var.reuse_existing ? 0 : 1
  depends_on      = [azurerm_cognitive_account.foundry]
  create_duration = "60s"
}

resource "azurerm_private_endpoint" "foundry" {
  name                = "pe-ais-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  depends_on = [time_sleep.foundry_settle]

  private_service_connection {
    name                           = "psc-ais"
    private_connection_resource_id = local.account_id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "ais-dns"
    private_dns_zone_ids = var.dns_zone_ids
  }
}

output "id" {
  description = "Resource ID of the AIServices (Foundry) cognitive account (created or referenced)."
  value       = local.account_id
}
output "name" {
  description = "Name of the AIServices (Foundry) cognitive account."
  value       = local.account_name
}
output "endpoint" {
  description = "AIServices account control endpoint (https://ais-<suffix>.cognitiveservices.azure.com/)."
  value       = local.account_endpoint
}
output "endpoint_openai_v1" {
  description = "GA OpenAI/v1 inference base for the AIServices account (…/openai/v1). Accepts gpt + OSS deployments with the model name in the body."
  value       = "${trimsuffix(replace(local.account_endpoint, ".cognitiveservices.azure.com", ".openai.azure.com"), "/")}/openai/v1"
}
output "endpoint_openai_host" {
  description = "AIServices account openai.azure.com host base (no path)."
  value       = trimsuffix(replace(local.account_endpoint, ".cognitiveservices.azure.com", ".openai.azure.com"), "/")
}
output "deployment_names" {
  description = "Model deployment names created by this module (empty in reuse mode; the account already has them)."
  value       = [for k, d in azurerm_cognitive_deployment.models : k]
}

locals {
  project_account_name = var.project_account_name != "" ? var.project_account_name : "aisproj-${var.suffix}"
  project_name         = "codexproj"
}

# NEW project-enabled AIServices account. azapi (not azurerm) because azurerm ~>4.20 has no
# allowProjectManagement argument. Fireworks models require the project route for Responses.
resource "azapi_resource" "project_account" {
  count     = var.enable_project_account ? 1 : 0
  type      = "Microsoft.CognitiveServices/accounts@2025-04-01-preview"
  name      = local.project_account_name
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  location  = var.location
  tags      = var.tags

  body = {
    kind     = "AIServices"
    sku      = { name = "S0" }
    identity = { type = "SystemAssigned" }
    properties = {
      allowProjectManagement = true
      customSubDomainName    = local.project_account_name
      disableLocalAuth       = true
      publicNetworkAccess    = "Enabled"
    }
  }
  response_export_values = ["properties.endpoints", "properties.endpoint"]
}

# Child project. Its inference route is /api/projects/<name>/openai/v1.
resource "azapi_resource" "project" {
  count     = var.enable_project_account ? 1 : 0
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = local.project_name
  parent_id = azapi_resource.project_account[0].id
  location  = var.location
  body = {
    identity   = { type = "SystemAssigned" }
    properties = {}
  }
}

output "project_account_id" {
  description = "Resource id of the project-enabled AIServices account (for RBAC + deployments). Null when disabled."
  value       = one(azapi_resource.project_account[*].id)
}

output "project_responses_base" {
  description = "Project-route OpenAI/v1 base for the sidecar backend: https://<acct>.services.ai.azure.com/api/projects/<proj>/openai/v1. Null when disabled."
  value       = var.enable_project_account ? "https://${local.project_account_name}.services.ai.azure.com/api/projects/${local.project_name}/openai/v1" : null
}
