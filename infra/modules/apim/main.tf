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

variable "openai_account_id" {
  type        = string
  description = "Resource ID of the Azure OpenAI account to grant the APIM identity access to."
}

variable "openai_endpoint" {
  type        = string
  description = "Base endpoint URL of the backing Azure OpenAI account."
}

variable "foundry_account_id" {
  type        = string
  description = "Resource ID of the AIServices (Foundry) account to grant the APIM identity inference access to."
}

variable "foundry_endpoint" {
  type        = string
  description = "AIServices OpenAI/v1 inference base (e.g. https://ais-<suffix>.openai.azure.com/openai/v1); used verbatim as the foundry API service_url."
}

# --- Cross-backend downgrade wiring (Phase 6) ---
# Budget downgrade can rewrite a request DOWN a consumer's mixed-family ladder. When the target model
# lives in the OTHER backend account, the policy switches backends (set-backend-service) and rewrites
# the request into that target's PROVEN native route: gpt -> oai path route, OSS -> ais v1 body route.
variable "openai_aliases" {
  type        = list(string)
  description = "Deployment aliases hosted on the Azure OpenAI account (gpt family). Used by both policies to decide whether a downgrade target is a gpt model (oai path route)."
}

variable "foundry_aliases" {
  type        = list(string)
  description = "Deployment aliases hosted on the AIServices account (OSS/partner family). Used by both policies to decide whether a downgrade target is an OSS model (ais v1 body route)."
}

variable "openai_path_base" {
  type        = string
  description = "Azure OpenAI account path-route base for cross-backend downgrade to a gpt model, e.g. https://oai-<suffix>.openai.azure.com/openai (the policy appends /deployments/{model}/chat/completions?api-version=...)."
}

variable "foundry_v1_base" {
  type        = string
  description = "AIServices account OpenAI/v1 base for cross-backend downgrade to an OSS model, e.g. https://ais-<suffix>.openai.azure.com/openai/v1 (the policy appends /chat/completions and sets the body model)."
}

variable "openai_api_version" {
  type        = string
  description = "api-version query value for the Azure OpenAI path route (used when a downgrade targets a gpt model)."
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

variable "token_quota" {
  type        = number
  description = "Per-consumer token quota per period."
}

variable "token_quota_period" {
  type        = string
  description = "Token quota reset period."
}

variable "allowed_models" {
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

resource "azurerm_api_management" "apim" {
  name                = "apim-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = var.sku_name

  virtual_network_type = "Internal"
  public_ip_address_id = var.public_ip_id

  virtual_network_configuration {
    subnet_id = var.apim_subnet_id
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "apim_to_openai" {
  scope                = var.openai_account_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

# APIM MI calls the AIServices account for OSS-model inference. "Cognitive Services User" is the
# inference data-plane role for AIServices (broader than the OpenAI-only role used above).
resource "azurerm_role_assignment" "apim_to_foundry" {
  scope                = var.foundry_account_id
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
  service_url           = "${trimsuffix(var.openai_endpoint, "/")}/openai"

  # Import the Azure OpenAI inference OpenAPI spec so the API has real operations
  # (chat/completions, embeddings, etc). Without operations APIM 404s every request.
  # service_url above overrides the spec's servers URL for the backend.
  import {
    content_format = "openapi+json-link"
    content_value  = var.openai_openapi_spec_url
  }

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }
}

# Per-API policy: teamId counter-key derivation, model-permission allowlist, and MI backend auth.
resource "azurerm_api_management_api_policy" "openai" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  xml_content = templatefile(var.policy_template_path, {
    client_auth_mode   = var.client_auth_mode
    entra_tenant_id    = var.entra_tenant_id
    entra_api_audience = var.entra_api_audience
    entra_team_claim   = var.entra_team_claim
    rate_tiers         = var.rate_tiers
    openai_aliases     = var.openai_aliases
    foundry_aliases    = var.foundry_aliases
    openai_path_base   = var.openai_path_base
    foundry_v1_base    = var.foundry_v1_base
    openai_api_version = var.openai_api_version
  })

  depends_on = [
    azurerm_role_assignment.apim_to_openai,
    azurerm_role_assignment.apim_to_foundry,
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
  service_url = var.foundry_endpoint

  subscription_key_parameter_names {
    header = "api-key"
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
    client_auth_mode   = var.client_auth_mode
    entra_tenant_id    = var.entra_tenant_id
    entra_api_audience = var.entra_api_audience
    entra_team_claim   = var.entra_team_claim
    rate_tiers         = var.rate_tiers
    openai_aliases     = var.openai_aliases
    foundry_aliases    = var.foundry_aliases
    openai_path_base   = var.openai_path_base
    foundry_v1_base    = var.foundry_v1_base
    openai_api_version = var.openai_api_version
  })

  depends_on = [
    azurerm_role_assignment.apim_to_openai,
    azurerm_role_assignment.apim_to_foundry,
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

output "private_ip" {
  description = "First private IP address assigned to the APIM instance inside the injected subnet (null until provisioned)."
  value       = try(azurerm_api_management.apim.private_ip_addresses[0], null)
}

resource "azurerm_api_management_named_value" "allowed_models" {
  name                = "allowed-models"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "allowed-models"
  value               = join(",", var.allowed_models)

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
