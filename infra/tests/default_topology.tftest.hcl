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

override_resource {
  target          = module.foundry.azapi_resource.project_account[0]
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/aisproj-abc123"
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
    foundry_account_name = "aisproj-test"
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
      module.apim.model_role_assignments.openai.scope == module.foundry.id &&
      module.apim.model_role_assignments.openai.role_definition_name == "Cognitive Services OpenAI User"
    )
    error_message = "APIM must grant the canonical account Cognitive Services OpenAI User at module.foundry.id."
  }

  assert {
    condition = (
      module.apim.model_role_assignments.foundry.scope == module.foundry.id &&
      module.apim.model_role_assignments.foundry.role_definition_name == "Cognitive Services User"
    )
    error_message = "APIM must grant the canonical account Cognitive Services User at module.foundry.id."
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

  assert {
    condition = (
      !var.legacy_gpt_compat_enabled &&
      !var.admin_ui_legacy_gpt_aliases_enabled
    )
    error_message = "Fresh/final defaults must keep both migration-only GPT compatibility flags disabled."
  }

  assert {
    condition = toset(keys(jsondecode(module.control_plane.alias_models_json_input))) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "The default Admin UI catalog must stay canonical-only."
  }

  assert {
    condition = alltrue([
      for policy in [
        module.apim.rendered_policy_xml["openai"],
        module.apim.rendered_policy_xml["vscode"],
        module.apim.rendered_policy_xml["foundry"],
        local.responses_policy_xml,
        ] : (
        !strcontains(policy, "gpt-5.4") &&
        strcontains(policy, "name=\"requestedModelAllowed\"") &&
        strcontains(policy, "if (allowed.Contains(requested)) { return true; }") &&
        strcontains(policy, "return false;")
      )
    ])
    error_message = "Compatibility-off policies must use exact allowlist authorization and contain no legacy GPT aliases."
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

run "legacy_gpt_compatibility_with_staged_admin_aliases" {
  command = plan

  variables {
    location                            = "eastus2"
    owner                               = "test@example.com"
    cost_center                         = "TEST"
    apim_publisher_name                 = "Test"
    apim_publisher_email                = "test@example.com"
    budget_alert_email                  = "test@example.com"
    budget_start_date                   = "2026-07-01T00:00:00Z"
    foundry_account_name                = "aisproj-test"
    legacy_gpt_compat_enabled           = true
    admin_ui_legacy_gpt_aliases_enabled = true
  }

  assert {
    condition = toset(keys(jsondecode(module.control_plane.alias_models_json_input))) == toset([
      "gpt-5.6-sol",
      "gpt-5.4",
      "gpt-5.4-mini",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "Task 7 staging must expose the canonical catalog plus both editable legacy GPT aliases."
  }

  assert {
    condition = alltrue([
      for policy in [
        module.apim.rendered_policy_xml["openai"],
        module.apim.rendered_policy_xml["vscode"],
        module.apim.rendered_policy_xml["foundry"],
        local.responses_policy_xml,
        ] : (
        strcontains(policy, "gpt-5.4") &&
        strcontains(policy, "gpt-5.4-mini") &&
        strcontains(policy, "gpt-5.6-sol") &&
        strcontains(policy, "name=\"requestedModelAllowed\"") &&
        strcontains(policy, "gptFamily.Contains(requested)") &&
        strcontains(policy, "allowed.Any(model => gptFamily.Contains(model))") &&
        strcontains(policy, "return \"gpt-5.6-sol\";")
      )
    ])
    error_message = "Compatibility-on policies must authorize GPT-family equivalents and canonicalize them to gpt-5.6-sol."
  }

  assert {
    condition = alltrue([
      for policy in [
        module.apim.rendered_policy_xml["openai"],
        module.apim.rendered_policy_xml["vscode"],
        ] : (
        length(split("name=\"requestedModelAllowed\"", policy)[0]) < length(split("name=\"downgradeSelectedDeployment\"", policy)[0]) &&
        length(split("name=\"downgradeSelectedDeployment\"", policy)[0]) < length(split("name=\"effectiveDeployment\"", policy)[0]) &&
        length(split("name=\"effectiveDeployment\"", policy)[0]) < length(split("<set-backend-service", policy)[0]) &&
        length(split("name=\"effectiveDeployment\"", policy)[0]) < length(split("<llm-token-limit", policy)[0]) &&
        strcontains(policy, "body[\"model\"] = (string)context.Variables[\"effectiveDeployment\"]")
      )
    ])
    error_message = "OpenAI/VS Code policies must authorize, select downgrade, canonicalize, then dispatch/token-limit in that order."
  }

  assert {
    condition = alltrue([
      for policy in [
        module.apim.rendered_policy_xml["foundry"],
        local.responses_policy_xml,
        ] : (
        length(split("name=\"requestedModelAllowed\"", policy)[0]) < length(split("name=\"downgradeSelectedModel\"", policy)[0]) &&
        length(split("name=\"downgradeSelectedModel\"", policy)[0]) < length(split("name=\"effectiveModel\"", policy)[0]) &&
        length(split("name=\"effectiveModel\"", policy)[0]) < length(split("body[\"model\"] = (string)context.Variables[\"effectiveModel\"]", policy)[0]) &&
        length(split("name=\"effectiveModel\"", policy)[0]) < length(split("<llm-token-limit", policy)[0]) &&
        strcontains(policy, "body[\"model\"] = (string)context.Variables[\"effectiveModel\"]")
      )
    ])
    error_message = "Foundry/Responses policies must authorize, select downgrade, canonicalize, then dispatch/token-limit in that order."
  }

  assert {
    condition = alltrue([
      for policy in [
        module.apim.rendered_policy_xml["openai"],
        module.apim.rendered_policy_xml["vscode"],
        module.apim.rendered_policy_xml["foundry"],
        local.responses_policy_xml,
        ] : (
        strcontains(policy, "name=\"deployment\" value=\"@((string)context.Variables[\"requestedDeployment\"])\"") &&
        strcontains(policy, "name=\"effectiveModel\"") &&
        strcontains(policy, "x-ai-gateway-requested-model") &&
        strcontains(policy, "x-ai-gateway-effective-model")
      )
    ])
    error_message = "Compatibility rewrites must preserve requested/effective model observability."
  }
}

run "policy_compatibility_survives_admin_alias_removal" {
  command = plan

  variables {
    location                  = "eastus2"
    owner                     = "test@example.com"
    cost_center               = "TEST"
    apim_publisher_name       = "Test"
    apim_publisher_email      = "test@example.com"
    budget_alert_email        = "test@example.com"
    budget_start_date         = "2026-07-01T00:00:00Z"
    foundry_account_name      = "aisproj-test"
    legacy_gpt_compat_enabled = true
  }

  assert {
    condition = toset(keys(jsondecode(module.control_plane.alias_models_json_input))) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "Task 8 must be able to remove Admin UI legacy aliases while policy compatibility remains enabled."
  }

  assert {
    condition = alltrue([
      for policy in [
        module.apim.rendered_policy_xml["openai"],
        module.apim.rendered_policy_xml["vscode"],
        module.apim.rendered_policy_xml["foundry"],
        local.responses_policy_xml,
      ] : strcontains(policy, "gptFamily.Contains(requested)")
    ])
    error_message = "Task 8 Admin UI cleanup must not disable policy compatibility for stragglers."
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

  override_module {
    target          = module.control_plane
    override_during = plan

    outputs = {
      codexproxy_fqdn = "codexproxy.internal.example"
    }
  }

  override_resource {
    target          = module.foundry.azapi_resource.project_account[0]
    override_during = plan

    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/aisproj-abc123"
    }
  }

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

  assert {
    condition     = azurerm_api_management_api.responses.service_url == "https://codexproxy.internal.example"
    error_message = "route_via_codexproxy must point the /responses service URL at the Codex proxy sidecar."
  }

  assert {
    condition     = azurerm_role_assignment.codexproxy_to_project_account[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/aisproj-abc123"
    error_message = "The Codex proxy role assignment must stay scoped to the canonical AIServices account."
  }
}
