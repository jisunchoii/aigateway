# --- /responses API — Responses-API surface for Codex CLI, backed by the LiteLLM bridge. ---
#
# Declared at root (not in the apim module) because its backend is the LiteLLM Container App, which
# lives in the control_plane module — and control_plane runs AFTER apim (it needs module.apim.id).
# So the API/policy that points at LiteLLM must sit where BOTH modules are visible.
#
# Routing: Codex config base_url = https://<apim-host>/responses, wire_api = "responses". Codex POSTs
# to {base_url}/responses, i.e. /responses/responses. APIM strips the "responses" path prefix, the
# wildcard operation matches the "/responses" remainder, and service_url (.../v1) makes the backend
# path .../v1/responses — LiteLLM's canonical Responses route.
#
# Created only when the LiteLLM bridge is enabled (litellm_image set).

resource "azurerm_api_management_api" "responses" {
  count                 = local.litellm_enabled ? 1 : 0
  name                  = "responses"
  resource_group_name   = azurerm_resource_group.rg.name
  api_management_name   = module.apim.name
  revision              = "1"
  display_name          = "Responses (LiteLLM bridge)"
  path                  = "responses"
  protocols             = ["https"]
  subscription_required = var.client_auth_mode != "entra-id"
  service_url           = "https://${module.control_plane.litellm_fqdn}/v1"

  subscription_key_parameter_names {
    header = "Ocp-Apim-Subscription-Key"
    query  = "api-key"
  }
}

# Wildcard POST so /responses/* routes (no OpenAPI import for the Responses API).
resource "azurerm_api_management_api_operation" "responses_proxy" {
  count               = local.litellm_enabled ? 1 : 0
  operation_id        = "proxy"
  api_name            = azurerm_api_management_api.responses[0].name
  api_management_name = module.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Proxy"
  method              = "POST"
  url_template        = "/*"
  description         = "Catch-all proxy to the LiteLLM Responses bridge."
}

# The APIM<->LiteLLM hop secret, presented by the policy as Authorization: Bearer {{litellm-master-key}}.
resource "azurerm_api_management_named_value" "litellm_master_key" {
  count               = local.litellm_enabled ? 1 : 0
  name                = "litellm-master-key"
  api_management_name = module.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "litellm-master-key"
  value               = local.litellm_master_key
  secret              = true
}

resource "azurerm_api_management_api_policy" "responses" {
  count               = local.litellm_enabled ? 1 : 0
  api_name            = azurerm_api_management_api.responses[0].name
  api_management_name = module.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content = templatefile("${path.root}/../policies/responses-pipeline.xml.tftpl", {
    client_auth_mode        = var.client_auth_mode
    entra_tenant_id         = var.entra_tenant_id
    entra_api_audience      = var.entra_api_audience
    entra_team_claim        = var.entra_team_claim
    rate_tiers              = var.rate_tiers
    model_tokens_per_minute = local.model_tokens_per_minute
  })

  depends_on = [
    azurerm_api_management_api_operation.responses_proxy,
    azurerm_api_management_named_value.litellm_master_key,
  ]

  lifecycle {
    precondition {
      condition     = var.client_auth_mode != "entra-id" || (var.entra_tenant_id != "" && var.entra_api_audience != "" && var.entra_team_claim != "")
      error_message = "entra_tenant_id, entra_api_audience, and entra_team_claim are required when client_auth_mode = entra-id."
    }
  }
}

resource "azurerm_api_management_api_diagnostic" "responses" {
  count                    = local.litellm_enabled ? 1 : 0
  identifier               = "applicationinsights"
  api_name                 = azurerm_api_management_api.responses[0].name
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
  count       = local.litellm_enabled ? 1 : 0
  type        = "Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01"
  resource_id = azurerm_api_management_api_diagnostic.responses[0].id
  body = {
    properties = {
      metrics = true
    }
  }
}

output "responses_endpoint" {
  description = "Codex CLI base_url for the Responses bridge (null until litellm_image is set)."
  value       = local.litellm_enabled ? "${module.apim.gateway_url}/responses" : null
}
