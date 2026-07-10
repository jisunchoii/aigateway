terraform {
  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

variable "name_suffix" {
  type        = string
  description = "Naming suffix (workload-env-region) appended to resource names."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group in which the APIM instance is created."
}

variable "location" {
  type        = string
  description = "Azure region for the APIM instance."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources in this module."
}

variable "sku_name" {
  type        = string
  description = "APIM SKU in 'Name_Capacity' format (e.g. Developer_1, Premium_1)."
}

variable "publisher_name" {
  type        = string
  description = "Display name of the API publisher shown in the developer portal."
}

variable "publisher_email" {
  type        = string
  description = "Contact email for the API publisher; receives admin notifications."
}

variable "apim_subnet_id" {
  type        = string
  description = "Resource ID of the subnet into which APIM is VNet-injected (no delegation required for classic tier)."
}

variable "public_ip_id" {
  type        = string
  description = "Resource ID of the Standard-SKU public IP required by stv2-platform APIM even in internal mode."
}

variable "public" {
  type        = bool
  default     = false
  description = "When true, APIM is created in EXTERNAL VNet mode (gateway published on a public VIP, reachable from the internet). When false (default), Internal mode keeps the gateway private (VNet-only). VNet injection is retained either way so APIM can reach the private model backends."
}

variable "model_account_id" {
  type        = string
  description = "Canonical project-enabled AIServices account ID."
}

variable "model_openai_v1_base" {
  type        = string
  description = "Canonical OpenAI/v1 inference base."
}

variable "policy_template_path" {
  type        = string
  description = "Path to the APIM pipeline policy XML file."
}

variable "foundry_policy_template_path" {
  type        = string
  description = "Path to the APIM foundry (Model Inference) pipeline policy XML template."
}

variable "openai_openapi_spec_url" {
  type        = string
  description = "URL of the Azure OpenAI inference OpenAPI spec imported to define API operations."
}

variable "appinsights_id" {
  type        = string
  description = "Resource ID of the Application Insights instance for the APIM logger."
}

variable "appinsights_connection_string" {
  type        = string
  sensitive   = true
  description = "Connection string of the Application Insights instance (used by the APIM logger)."
}

variable "tokens_per_minute" {
  type        = number
  description = "Per-consumer token-per-minute limit."
}

variable "model_tokens_per_minute" {
  type        = map(number)
  description = "Default per-model token-per-minute limits, derived from model deployment capacity."

  validation {
    condition     = alltrue([for v in values(var.model_tokens_per_minute) : v > 0])
    error_message = "model_tokens_per_minute values must be positive numbers."
  }
}

variable "token_quota" {
  type        = number
  description = "Per-consumer token quota per period."
}

variable "token_quota_period" {
  type        = string
  description = "Token quota reset period."
}

variable "allowed_model_names" {
  type        = list(string)
  description = "Allowed deployment aliases."
}

variable "rate_tiers" {
  type        = map(object({ tpm = number, quota = number, period = string }))
  description = "Named rate-limit tiers (small/medium/large). Each becomes literal APIM named values the policy <choose>s by consumer tier."
  validation {
    condition = alltrue([for t in values(var.rate_tiers) :
    contains(["Hourly", "Daily", "Weekly", "Monthly"], t.period) && t.tpm > 0 && t.quota > 0])
    error_message = "each tier needs tpm>0, quota>0, period in Hourly/Daily/Weekly/Monthly."
  }
}

variable "client_auth_mode" {
  type        = string
  description = "subscription-key | entra-id."
}

variable "entra_tenant_id" {
  type        = string
  description = "Entra tenant for validate-jwt."
}

variable "entra_api_audience" {
  type        = string
  description = "Expected audience claim."
}

variable "entra_team_claim" {
  type        = string
  description = "JWT claim used to derive consumerId."
}

locals {
  allowed_models = var.allowed_model_names
}

resource "azurerm_api_management" "apim" {
  name                = "apim-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = var.sku_name

  virtual_network_type = var.public ? "External" : "Internal"
  public_ip_address_id = var.public_ip_id

  virtual_network_configuration {
    subnet_id = var.apim_subnet_id
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

removed {
  from = azurerm_role_assignment.apim_to_openai

  lifecycle {
    destroy = false
  }
}

moved {
  from = azurerm_role_assignment.apim_to_foundry
  to   = azurerm_role_assignment.apim_to_model_foundry
}

resource "azurerm_role_assignment" "apim_to_model_openai" {
  scope                = var.model_account_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

# APIM MI calls the canonical AIServices account for unified inference. "Cognitive Services User"
# is the broader inference data-plane role needed for non-OpenAI models on the same account.
resource "azurerm_role_assignment" "apim_to_model_foundry" {
  scope                = var.model_account_id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

resource "azurerm_role_assignment" "apim_to_appinsights" {
  scope                = var.appinsights_id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

resource "azurerm_api_management_api" "openai" {
  name                  = "azure-openai"
  resource_group_name   = var.resource_group_name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "Azure OpenAI"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = var.client_auth_mode != "entra-id"
  service_url           = var.model_openai_v1_base

  # Import the Azure OpenAI inference OpenAPI spec so the API has real operations
  # (chat/completions, embeddings, etc). Without operations APIM 404s every request.
  # service_url above overrides the spec's servers URL for the backend.
  import {
    content_format = "openapi+json-link"
    content_value  = var.openai_openapi_spec_url
  }

  subscription_key_parameter_names {
    header = "api-key"
    query  = "subscription-key"
  }
}

# Per-API policy: teamId counter-key derivation, model-permission allowlist, and MI backend auth.
resource "azurerm_api_management_api_policy" "openai" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  xml_content = templatefile(var.policy_template_path, {
    client_auth_mode        = var.client_auth_mode
    entra_tenant_id         = var.entra_tenant_id
    entra_api_audience      = var.entra_api_audience
    entra_team_claim        = var.entra_team_claim
    rate_tiers              = var.rate_tiers
    model_tokens_per_minute = var.model_tokens_per_minute
    model_openai_v1_base    = var.model_openai_v1_base
  })

  depends_on = [
    azurerm_role_assignment.apim_to_model_openai,
    azurerm_role_assignment.apim_to_model_foundry,
    azurerm_api_management_named_value.allowed_models,
    azurerm_api_management_named_value.tokens_per_minute,
    azurerm_api_management_named_value.token_quota,
    azurerm_api_management_named_value.token_quota_period,
    azurerm_api_management_named_value.consumer_config_json,
    azurerm_api_management_named_value.tier,
    azurerm_api_management_api_diagnostic.openai,
  ]

  lifecycle {
    precondition {
      condition     = var.client_auth_mode != "entra-id" || (var.entra_tenant_id != "" && var.entra_api_audience != "" && var.entra_team_claim != "")
      error_message = "entra_tenant_id, entra_api_audience, and entra_team_claim are required when client_auth_mode = entra-id."
    }
  }
}

# VS Code BYOK facade. VS Code supports custom request headers, including the APIM default
# `Ocp-Apim-Subscription-Key`; keep it off the URL so keys don't leak via query strings.
resource "azurerm_api_management_api" "vscode_openai" {
  name                  = "vscode-openai"
  resource_group_name   = var.resource_group_name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "VS Code Models"
  path                  = "vscode/models"
  protocols             = ["https"]
  subscription_required = true
  service_url           = var.model_openai_v1_base

  import {
    content_format = "openapi+json-link"
    content_value  = var.openai_openapi_spec_url
  }

  subscription_key_parameter_names {
    header = "Ocp-Apim-Subscription-Key"
    query  = "api-key"
  }
}

resource "azurerm_api_management_api_policy" "vscode_openai" {
  api_name            = azurerm_api_management_api.vscode_openai.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  xml_content = templatefile(var.policy_template_path, {
    client_auth_mode        = "subscription-key"
    entra_tenant_id         = var.entra_tenant_id
    entra_api_audience      = var.entra_api_audience
    entra_team_claim        = var.entra_team_claim
    rate_tiers              = var.rate_tiers
    model_tokens_per_minute = var.model_tokens_per_minute
    model_openai_v1_base    = var.model_openai_v1_base
  })

  depends_on = [
    azurerm_role_assignment.apim_to_model_openai,
    azurerm_role_assignment.apim_to_model_foundry,
    azurerm_api_management_named_value.allowed_models,
    azurerm_api_management_named_value.tokens_per_minute,
    azurerm_api_management_named_value.token_quota,
    azurerm_api_management_named_value.token_quota_period,
    azurerm_api_management_named_value.consumer_config_json,
    azurerm_api_management_named_value.tier,
    azurerm_api_management_api_diagnostic.vscode_openai,
  ]
}

resource "azurerm_api_management_logger" "appinsights" {
  name                = "appinsights"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  resource_id         = var.appinsights_id

  application_insights {
    connection_string = var.appinsights_connection_string
  }

  depends_on = [azurerm_role_assignment.apim_to_appinsights]
}

resource "azurerm_api_management_api_diagnostic" "openai" {
  identifier               = "applicationinsights"
  api_name                 = azurerm_api_management_api.openai.name
  api_management_name      = azurerm_api_management.apim.name
  resource_group_name      = var.resource_group_name
  api_management_logger_id = azurerm_api_management_logger.appinsights.id

  sampling_percentage       = 100
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "information"
  http_correlation_protocol = "W3C"
}

resource "azurerm_api_management_api_diagnostic" "vscode_openai" {
  identifier               = "applicationinsights"
  api_name                 = azurerm_api_management_api.vscode_openai.name
  api_management_name      = azurerm_api_management.apim.name
  resource_group_name      = var.resource_group_name
  api_management_logger_id = azurerm_api_management_logger.appinsights.id

  sampling_percentage       = 100
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "information"
  http_correlation_protocol = "W3C"
}

# Enable custom metrics on the diagnostic (azurerm 4.x doesn't expose the `metrics` property).
resource "azapi_update_resource" "openai_diag_metrics" {
  type        = "Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01"
  resource_id = azurerm_api_management_api_diagnostic.openai.id
  body = {
    properties = {
      metrics = true
    }
  }
}

resource "azapi_update_resource" "vscode_openai_diag_metrics" {
  type        = "Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01"
  resource_id = azurerm_api_management_api_diagnostic.vscode_openai.id
  body = {
    properties = {
      metrics = true
    }
  }
}

# --- Foundry (AIServices Model Inference API) — separate API, path=foundry, OSS/partner models. ---
resource "azurerm_api_management_api" "foundry" {
  name                  = "foundry"
  resource_group_name   = var.resource_group_name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "Foundry (Model Inference)"
  path                  = "foundry"
  protocols             = ["https"]
  subscription_required = var.client_auth_mode != "entra-id"
  # GA OpenAI/v1 inference base (…/openai/v1). Clients call POST /foundry/chat/completions with the
  # deployment name in the body "model" field; APIM appends the path to this service_url.
  service_url = var.model_openai_v1_base

  subscription_key_parameter_names {
    header = "Ocp-Apim-Subscription-Key"
    query  = "api-key"
  }
}

# Wildcard operation so every /foundry/* path routes (no OpenAPI import for the Model Inference API).
resource "azurerm_api_management_api_operation" "foundry_proxy" {
  operation_id        = "proxy"
  api_name            = azurerm_api_management_api.foundry.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "Proxy"
  method              = "POST"
  url_template        = "/*"
  description         = "Catch-all proxy to the AIServices Model Inference endpoint."
}

resource "azurerm_api_management_api_policy" "foundry" {
  api_name            = azurerm_api_management_api.foundry.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  xml_content = templatefile(var.foundry_policy_template_path, {
    client_auth_mode        = var.client_auth_mode
    entra_tenant_id         = var.entra_tenant_id
    entra_api_audience      = var.entra_api_audience
    entra_team_claim        = var.entra_team_claim
    rate_tiers              = var.rate_tiers
    model_tokens_per_minute = var.model_tokens_per_minute
    model_openai_v1_base    = var.model_openai_v1_base
  })

  depends_on = [
    azurerm_role_assignment.apim_to_model_openai,
    azurerm_role_assignment.apim_to_model_foundry,
    azurerm_api_management_named_value.allowed_models,
    azurerm_api_management_named_value.tokens_per_minute,
    azurerm_api_management_named_value.token_quota,
    azurerm_api_management_named_value.token_quota_period,
    azurerm_api_management_named_value.consumer_config_json,
    azurerm_api_management_named_value.tier,
    azurerm_api_management_api_diagnostic.foundry,
    azurerm_api_management_api_operation.foundry_proxy,
  ]

  lifecycle {
    precondition {
      condition     = var.client_auth_mode != "entra-id" || (var.entra_tenant_id != "" && var.entra_api_audience != "" && var.entra_team_claim != "")
      error_message = "entra_tenant_id, entra_api_audience, and entra_team_claim are required when client_auth_mode = entra-id."
    }
  }
}

resource "azurerm_api_management_api_diagnostic" "foundry" {
  identifier               = "applicationinsights"
  api_name                 = azurerm_api_management_api.foundry.name
  api_management_name      = azurerm_api_management.apim.name
  resource_group_name      = var.resource_group_name
  api_management_logger_id = azurerm_api_management_logger.appinsights.id

  sampling_percentage       = 100
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "information"
  http_correlation_protocol = "W3C"
}

resource "azapi_update_resource" "foundry_diag_metrics" {
  type        = "Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01"
  resource_id = azurerm_api_management_api_diagnostic.foundry.id
  body = {
    properties = {
      metrics = true
    }
  }
}

output "id" {
  description = "Resource ID of the APIM instance."
  value       = azurerm_api_management.apim.id
}

output "logger_id" {
  description = "Resource ID of the Application Insights APIM logger (for diagnostics on root-level APIs like /responses)."
  value       = azurerm_api_management_logger.appinsights.id
}

output "name" {
  description = "Name of the APIM instance."
  value       = azurerm_api_management.apim.name
}

output "principal_id" {
  description = "Object ID of the system-assigned managed identity (used for RBAC grants in Task 9)."
  value       = azurerm_api_management.apim.identity[0].principal_id
}

output "gateway_url" {
  description = "Internal gateway URL for the APIM instance."
  value       = azurerm_api_management.apim.gateway_url
}

output "vscode_base_url" {
  description = "Base URL prefix for VS Code BYOK model URLs."
  value       = "${azurerm_api_management.apim.gateway_url}/vscode/models"
}

output "private_ip" {
  description = "First private IP address assigned to the APIM instance inside the injected subnet (null until provisioned)."
  value       = try(azurerm_api_management.apim.private_ip_addresses[0], null)
}

resource "azurerm_api_management_named_value" "allowed_models" {
  name                = "allowed-models"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "allowed-models"
  value               = join(",", local.allowed_models)

  lifecycle {
    # The Phase 3a config-sync worker is the runtime owner of this value (it writes it from
    # the Cosmos config doc). Terraform sets the initial value on create but must not revert
    # the worker's updates on subsequent applies.
    ignore_changes = [value]
  }
}

resource "azurerm_api_management_named_value" "tokens_per_minute" {
  name                = "tokens-per-minute"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "tokens-per-minute"
  value               = tostring(var.tokens_per_minute)

  lifecycle {
    # The Phase 3a config-sync worker is the runtime owner of this value (it writes it from
    # the Cosmos config doc). Terraform sets the initial value on create but must not revert
    # the worker's updates on subsequent applies.
    ignore_changes = [value]
  }
}

resource "azurerm_api_management_named_value" "token_quota" {
  name                = "token-quota"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "token-quota"
  value               = tostring(var.token_quota)

  lifecycle {
    # The Phase 3a config-sync worker is the runtime owner of this value (it writes it from
    # the Cosmos config doc). Terraform sets the initial value on create but must not revert
    # the worker's updates on subsequent applies.
    ignore_changes = [value]
  }
}

resource "azurerm_api_management_named_value" "token_quota_period" {
  name                = "token-quota-period"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "token-quota-period"
  value               = var.token_quota_period

  lifecycle {
    # The Phase 3a config-sync worker is the runtime owner of this value (it writes it from
    # the Cosmos config doc). Terraform sets the initial value on create but must not revert
    # the worker's updates on subsequent applies.
    ignore_changes = [value]
  }
}

resource "azurerm_api_management_named_value" "consumer_config_json" {
  name                = "consumer-config-json"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "consumer-config-json"
  # base64 of "{}" — an empty team bundle. The config-sync worker owns this value at runtime
  # (writes base64(JSON) of all consumer_config docs); Terraform sets only the initial empty value.
  value = "e30="

  lifecycle {
    ignore_changes = [value]
  }
}

# Per-tier literal named values (tier-<name>-tpm/-quota/-period). The policy substitutes these as
# LITERALS into per-tier llm-token-limit blocks (APIM rejects expressions on tpm/quota). These are
# IaC-owned (sourced from the rate_tiers tfvar) — NOT worker-written — so tfvars edits flow through
# normally (no ignore_changes).
locals {
  tier_named_values = merge([
    for tname, t in var.rate_tiers : {
      "tier-${tname}-tpm"    = tostring(t.tpm)
      "tier-${tname}-quota"  = tostring(t.quota)
      "tier-${tname}-period" = t.period
    }
  ]...)
}

resource "azurerm_api_management_named_value" "tier" {
  for_each            = local.tier_named_values
  name                = each.key
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = each.key
  value               = each.value
}
