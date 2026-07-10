mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "random" {
  mock_resource "random_string" {
    defaults = {
      result = "abc123"
    }
  }
}
mock_provider "time" {}

override_data {
  target          = data.azurerm_client_config.current
  override_during = plan

  values = {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "11111111-1111-1111-1111-111111111111"
  }
}

override_data {
  target          = module.keyvault.data.azurerm_client_config.current
  override_during = plan

  values = {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "11111111-1111-1111-1111-111111111111"
  }
}

run "default_model_topology" {
  command = plan

  variables {
    location             = "eastus2"
    owner                = "test@example.com"
    cost_center          = "TEST"
    apim_publisher_name  = "Test"
    apim_publisher_email = "test@example.com"
    budget_alert_email   = "test@example.com"
    budget_start_date    = "2026-07-01T00:00:00Z"
  }

  assert {
    condition = toset(local.allowed_models) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "Allowed models must derive from the four canonical deployments."
  }

  assert {
    condition = toset(module.foundry.deployment_names) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "Fresh deployments must create the canonical model set."
  }

  assert {
    condition = (
      var.model_deployments["gpt-5.6-sol"].model_format == "OpenAI" &&
      var.model_deployments["gpt-5.6-sol"].model_version == "2026-07-09" &&
      var.model_deployments["gpt-5.6-sol"].sku_name == "GlobalStandard" &&
      var.model_deployments["gpt-5.6-sol"].capacity == 500 &&
      var.model_deployments["FW-GLM-5.2"].model_format == "Fireworks" &&
      var.model_deployments["FW-GLM-5.2"].model_version == "1" &&
      var.model_deployments["FW-GLM-5.2"].sku_name == "DataZoneStandard" &&
      var.model_deployments["FW-GLM-5.2"].capacity == 500 &&
      var.model_deployments["DeepSeek-V4-Pro"].model_format == "DeepSeek" &&
      var.model_deployments["DeepSeek-V4-Pro"].model_version == "2026-04-23" &&
      var.model_deployments["DeepSeek-V4-Pro"].sku_name == "GlobalStandard" &&
      var.model_deployments["DeepSeek-V4-Pro"].capacity == 500 &&
      var.model_deployments["grok-4.3"].model_format == "xAI" &&
      var.model_deployments["grok-4.3"].model_version == "1" &&
      var.model_deployments["grok-4.3"].sku_name == "GlobalStandard" &&
      var.model_deployments["grok-4.3"].capacity == 10
    )
    error_message = "The root module must pin the canonical deployment attributes for every default model."
  }

  assert {
    condition = local.model_tokens_per_minute == {
      "gpt-5.6-sol"     = 500000
      "FW-GLM-5.2"      = 500000
      "DeepSeek-V4-Pro" = 500000
      "grok-4.3"        = 10000
    }
    error_message = "model_tokens_per_minute must derive directly from deployment capacity * 1000."
  }

  assert {
    condition     = module.foundry.project_responses_base != null
    error_message = "A fresh deployment must create the project route."
  }

  assert {
    condition     = module.apim.allowed_models_seed_value == join(",", local.allowed_models)
    error_message = "Terraform must seed APIM allowed-models from the canonical deployment catalog."
  }

  assert {
    condition = (
      length(random_password.codexproxy_key) == 0 &&
      length(azurerm_api_management_named_value.codexproxy_key) == 0 &&
      length(azurerm_role_assignment.codexproxy_to_project_account) == 0
    )
    error_message = "Codex proxy secrets and RBAC must stay absent when codexproxy_image is unset."
  }

  assert {
    condition = (
      strcontains(azurerm_api_management_api_policy.responses.xml_content, "authentication-managed-identity resource=\"https://cognitiveservices.azure.com\"") &&
      !strcontains(azurerm_api_management_api_policy.responses.xml_content, "{{codexproxy-key}}")
    )
    error_message = "The default /responses policy must stay direct-to-AIServices until route_via_codexproxy is enabled."
  }
}

run "catalog_interfaces_follow_allowed_models" {
  command = plan

  variables {
    location              = "eastus2"
    owner                 = "test@example.com"
    cost_center           = "TEST"
    apim_publisher_name   = "Test"
    apim_publisher_email  = "test@example.com"
    budget_alert_email    = "test@example.com"
    budget_start_date     = "2026-07-01T00:00:00Z"
    admin_ui_image        = "example.azurecr.io/admin-ui:latest"
    entra_tenant_id       = "11111111-1111-1111-1111-111111111111"
    bff_api_audience      = "api://gateway-bff"
    spa_client_id         = "22222222-2222-2222-2222-222222222222"
    admin_group_object_id = "33333333-3333-3333-3333-333333333333"
  }

  assert {
    condition     = module.control_plane.alias_models_json_input == jsonencode({ for model in local.allowed_models : model => model })
    error_message = "The Admin UI must receive the same canonical catalog that Terraform seeds into APIM."
  }
}

run "codexproxy_backend_can_be_preprovisioned" {
  command = plan

  variables {
    location             = "eastus2"
    owner                = "test@example.com"
    cost_center          = "TEST"
    apim_publisher_name  = "Test"
    apim_publisher_email = "test@example.com"
    budget_alert_email   = "test@example.com"
    budget_start_date    = "2026-07-01T00:00:00Z"
    codexproxy_image     = "example.azurecr.io/codexproxy:latest"
  }

  assert {
    condition = (
      local.codexproxy_enabled &&
      length(random_password.codexproxy_key) == 1 &&
      length(azurerm_api_management_named_value.codexproxy_key) == 1 &&
      length(azurerm_role_assignment.codexproxy_to_project_account) == 1
    )
    error_message = "Setting codexproxy_image must create the staged hop key and proxy RBAC."
  }

  assert {
    condition = (
      strcontains(azurerm_api_management_api_policy.responses.xml_content, "authentication-managed-identity resource=\"https://cognitiveservices.azure.com\"") &&
      !strcontains(azurerm_api_management_api_policy.responses.xml_content, "{{codexproxy-key}}")
    )
    error_message = "Pre-provisioning the Codex proxy must not flip /responses until route_via_codexproxy is enabled."
  }
}

run "codexproxy_route_flip_injects_hop_key" {
  command = plan

  variables {
    location             = "eastus2"
    owner                = "test@example.com"
    cost_center          = "TEST"
    apim_publisher_name  = "Test"
    apim_publisher_email = "test@example.com"
    budget_alert_email   = "test@example.com"
    budget_start_date    = "2026-07-01T00:00:00Z"
    codexproxy_image     = "example.azurecr.io/codexproxy:latest"
    route_via_codexproxy = true
  }

  assert {
    condition = (
      strcontains(azurerm_api_management_api_policy.responses.xml_content, "{{codexproxy-key}}") &&
      !strcontains(azurerm_api_management_api_policy.responses.xml_content, "authentication-managed-identity resource=\"https://cognitiveservices.azure.com\"")
    )
    error_message = "route_via_codexproxy must switch the /responses policy from direct MI auth to the hop-key sidecar path."
  }
}
