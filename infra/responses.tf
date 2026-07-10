# --- /responses API — Responses-API surface for Codex CLI, backed by the canonical AIServices account. ---
#
# Codex CLI is Responses-only (wire_api = "responses"). The canonical AIServices account exposes the
# Azure OpenAI-compatible /openai/v1/responses path, and gpt-5.6-sol / FW-GLM-5.2 /
# DeepSeek-V4-Pro / grok-4.3 all accept native Responses there — including hosted tools
# (web_search) and function tools (verified against the live deployments). So /responses is just
# another wildcard-proxy API pointed at the same canonical account as /foundry, with the same
# governance policy and managed-identity auth. No LiteLLM hop.
#
# Routing: Codex config base_url = https://<apim-host>/responses, wire_api = "responses". Codex POSTs
# to {base_url}/responses, i.e. /responses/responses. APIM strips the "responses" path prefix, the
# wildcard operation matches the "/responses" remainder, and service_url (…/openai/v1) makes the
# backend path …/openai/v1/responses — the AIServices account's native Responses route.
#
# Declared at root (not in the apim module) alongside the other root wiring; it reuses the apim
# module's outputs (name, logger_id, gateway_url) and the canonical account endpoint. The APIM
# managed identity already has Cognitive Services OpenAI User on the canonical AIServices account
# (granted in the apim module), so the managed-identity auth in the policy works with no additional
# role assignment.

resource "azurerm_api_management_api" "responses" {
  name                  = "responses"
  resource_group_name   = azurerm_resource_group.rg.name
  api_management_name   = module.apim.name
  revision              = "1"
  display_name          = "Responses (AIServices native)"
  path                  = "responses"
  protocols             = ["https"]
  subscription_required = var.client_auth_mode != "entra-id"
  # GA OpenAI/v1 inference base (…/openai/v1). Codex calls POST /responses/responses with the
  # deployment name in the body "model" field; APIM appends the path to this service_url.
  # When the Codex proxy sidecar is enabled, /responses fronts the sidecar (which normalizes Codex
  # payloads + forwards to the canonical project route). Otherwise it hits the canonical AIServices
  # account directly.
  service_url = var.route_via_codexproxy ? "https://${module.control_plane.codexproxy_fqdn}" : module.foundry.endpoint_openai_v1

  subscription_key_parameter_names {
    header = "Ocp-Apim-Subscription-Key"
    query  = "api-key"
  }
}

# Wildcard POST so /responses/* routes (no OpenAPI import for the Responses API).
resource "azurerm_api_management_api_operation" "responses_proxy" {
  operation_id        = "proxy"
  api_name            = azurerm_api_management_api.responses.name
  api_management_name = module.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Proxy"
  method              = "POST"
  url_template        = "/*"
  description         = "Catch-all proxy to the AIServices native Responses endpoint."
}

locals {
  responses_policy_xml = templatefile("${path.root}/../policies/responses-pipeline.xml.tftpl", {
    client_auth_mode          = var.client_auth_mode
    entra_tenant_id           = var.entra_tenant_id
    entra_api_audience        = var.entra_api_audience
    entra_team_claim          = var.entra_team_claim
    rate_tiers                = var.rate_tiers
    model_tokens_per_minute   = local.model_tokens_per_minute
    codexproxy_enabled        = var.route_via_codexproxy
    legacy_gpt_compat_enabled = var.legacy_gpt_compat_enabled
  })
}

resource "azurerm_api_management_api_policy" "responses" {
  api_name            = azurerm_api_management_api.responses.name
  api_management_name = module.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content         = local.responses_policy_xml

  depends_on = [
    azurerm_api_management_api_operation.responses_proxy,
  ]

  lifecycle {
    precondition {
      condition     = var.client_auth_mode != "entra-id" || (var.entra_tenant_id != "" && var.entra_api_audience != "" && var.entra_team_claim != "")
      error_message = "entra_tenant_id, entra_api_audience, and entra_team_claim are required when client_auth_mode = entra-id."
    }
  }
}

resource "azurerm_api_management_api_diagnostic" "responses" {
  identifier               = "applicationinsights"
  api_name                 = azurerm_api_management_api.responses.name
  api_management_name      = module.apim.name
  resource_group_name      = azurerm_resource_group.rg.name
  api_management_logger_id = module.apim.logger_id

  sampling_percentage       = 100
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "information"
  http_correlation_protocol = "W3C"
}

resource "azapi_update_resource" "responses_diag_metrics" {
  type        = "Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01"
  resource_id = azurerm_api_management_api_diagnostic.responses.id
  body = {
    properties = {
      metrics = true
    }
  }
}

output "responses_endpoint" {
  description = "Codex CLI base_url for the native Responses API."
  value       = "${module.apim.gateway_url}/responses"
}
