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

override_resource {
  target          = module.apim.azurerm_api_management.apim
  override_during = plan

  values = {
    id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-dev-eus2/providers/Microsoft.ApiManagement/service/apim-aigw-dev-eus2"
    name        = "apim-aigw-dev-eus2"
    gateway_url = "https://apim.internal.example"
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
    codexproxy_image     = ""
    searchmcp_image      = ""
  }

  assert {
    condition = toset(local.allowed_models) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "The canonical deployment map must be the only model catalog."
  }

  assert {
    condition     = output.model_gateway_base_url == "${module.apim.gateway_url}/openai/v1"
    error_message = "All non-VS-Code clients must use the versionless Model Gateway base."
  }

  assert {
    condition = module.apim.api_contract.model_gateway.operations == {
      chat      = "/chat/completions"
      responses = "/responses"
    }
    error_message = "Model Gateway must own Chat and Responses."
  }

  assert {
    condition = (
      length(random_password.codexproxy_key) == 0 &&
      length(azurerm_role_assignment.codexproxy_to_project_account) == 0 &&
      module.apim.codexproxy_contract.named_value_count == 0 &&
      strcontains(module.apim.rendered_policy_xml.model_gateway, "code=\"503\"")
    )
    error_message = "The bootstrap apply must not create a fake sidecar route or direct Responses fallback."
  }

  assert {
    condition     = output.search_mcp_url == null
    error_message = "search_mcp_url must stay null until the Search MCP sidecar is enabled."
  }

  assert {
    condition     = module.control_plane.searchmcp_fqdn == null
    error_message = "searchmcp_fqdn must stay null until the Search MCP sidecar is enabled."
  }

  assert {
    condition     = module.control_plane.searchmcp_contract == null
    error_message = "searchmcp_contract must stay null until the Search MCP sidecar is enabled."
  }

  assert {
    condition = module.control_plane.alias_models_json_input == jsonencode({
      "DeepSeek-V4-Pro" = "DeepSeek-V4-Pro"
      "FW-GLM-5.2"      = "FW-GLM-5.2"
      "gpt-5.6-sol"     = "gpt-5.6-sol"
      "grok-4.3"        = "grok-4.3"
    })
    error_message = "Admin UI must receive exactly the deployment-derived catalog."
  }
}

run "sidecar_image_enables_responses" {
  command = plan

  override_module {
    target          = module.control_plane
    override_during = plan
    outputs = {
      codexproxy_fqdn = "codexproxy.internal.example"
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
    foundry_account_name = "aisproj-test"
    codexproxy_image     = "example.azurecr.io/codexproxy:immutable"
    searchmcp_image      = ""
  }

  assert {
    condition = (
      length(random_password.codexproxy_key) == 1 &&
      length(azurerm_role_assignment.codexproxy_to_project_account) == 1 &&
      module.apim.codexproxy_contract.enabled &&
      module.apim.codexproxy_contract.base_url == "https://codexproxy.internal.example" &&
      module.apim.codexproxy_contract.named_value_count == 1 &&
      strcontains(module.apim.rendered_policy_xml.model_gateway, "{{codexproxy-key}}") &&
      !strcontains(module.apim.rendered_policy_xml.model_gateway, "Responses backend is not configured")
    )
    error_message = "Setting codexproxy_image must atomically enable the only Responses backend."
  }

  assert {
    condition     = azurerm_role_assignment.codexproxy_to_project_account[0].scope == module.foundry.id
    error_message = "The sidecar identity must receive Cognitive Services User on the canonical account."
  }
}

run "searchmcp_image_enables_container_app_wiring" {
  command = plan

  override_module {
    target          = module.control_plane
    override_during = plan
    outputs = {
      searchmcp_fqdn = "searchmcp.internal.example"
      searchmcp_contract = {
        name            = "ca-searchmcp-aigw-dev-eus2"
        target_port     = 8790
        identity_source = "codexproxy"
        env_names = [
          "AZURE_CLIENT_ID",
          "FOUNDRY_PROJECT_BASE",
          "PORT",
          "PROXY_KEY",
          "PROXY_KEY_VERSION",
          "SEARCH_MODEL",
        ]
        known_env = {
          FOUNDRY_PROJECT_BASE = "https://aisproj-test.services.ai.azure.com/api/projects/codexproj/openai/v1"
          SEARCH_MODEL         = "gpt-5.6-sol"
          PORT                 = "8790"
        }
      }
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
    foundry_account_name = "aisproj-test"
    codexproxy_image     = ""
    searchmcp_image      = "example.azurecr.io/searchmcp:immutable"
  }

  assert {
    condition = (
      length(random_password.codexproxy_key) == 1 &&
      length(azurerm_role_assignment.codexproxy_to_project_account) == 1 &&
      can(module.control_plane.searchmcp_contract) &&
      module.control_plane.searchmcp_contract.name == "ca-searchmcp-aigw-dev-eus2" &&
      module.control_plane.searchmcp_contract.target_port == 8790 &&
      module.control_plane.searchmcp_contract.identity_source == "codexproxy" &&
      toset(module.control_plane.searchmcp_contract.env_names) == toset([
        "AZURE_CLIENT_ID",
        "FOUNDRY_PROJECT_BASE",
        "PORT",
        "PROXY_KEY",
        "PROXY_KEY_VERSION",
        "SEARCH_MODEL",
      ]) &&
      module.control_plane.searchmcp_contract.known_env == {
        FOUNDRY_PROJECT_BASE = module.foundry.project_responses_base
        SEARCH_MODEL         = "gpt-5.6-sol"
        PORT                 = "8790"
      } &&
      module.apim.codexproxy_contract.enabled == false &&
      module.apim.codexproxy_contract.named_value_count == 1 &&
      module.apim.api_contract.search_mcp.service_url == "https://searchmcp.internal.example" &&
      module.apim.api_contract.search_mcp.operations.mcp.policy.authorization_header == "Bearer {{codexproxy-key}}" &&
      output.search_mcp_url == "${module.apim.gateway_url}/mcp/"
    )
    error_message = "Setting searchmcp_image must create the Search MCP app on port 8790 with the shared identity, shared hop key/base, and the /mcp/ root output."
  }

  assert {
    condition = (
      can(module.control_plane.searchmcp_contract) &&
      length(regexall(
        "(?s)resource \"azurerm_container_app\" \"searchmcp\" \\{.*?ingress \\{\\s*external_enabled = true\\s*target_port\\s*=\\s*8790",
        file("modules/control_plane/main.tf")
      )) == 1
    )
    error_message = "The Search MCP container app must be VNet-reachable on the environment load balancer so APIM can forward /mcp traffic to it."
  }

  assert {
    condition = (
      can(module.control_plane.searchmcp_contract) &&
      length(regexall(
        "(?s)resource \"azurerm_container_app\" \"codexproxy\" \\{.*?secret \\{\\s*name\\s*=\\s*\"proxy-key\"\\s*value\\s*=\\s*var.codexproxy_key\\s*\\}.*?env \\{\\s*name\\s*=\\s*\"PROXY_KEY\"\\s*secret_name\\s*=\\s*\"proxy-key\"\\s*\\}",
        file("modules/control_plane/main.tf")
      )) == 1 &&
      length(regexall(
        "(?s)resource \"azurerm_container_app\" \"searchmcp\" \\{.*?secret \\{\\s*name\\s*=\\s*\"proxy-key\"\\s*value\\s*=\\s*var.codexproxy_key\\s*\\}.*?env \\{\\s*name\\s*=\\s*\"PROXY_KEY\"\\s*secret_name\\s*=\\s*\"proxy-key\"\\s*\\}",
        file("modules/control_plane/main.tf")
      )) == 1 &&
      length(regexall(
        "proxy_key_revision\\s*=\\s*nonsensitive\\(substr\\(sha256\\(var.codexproxy_key\\), 0, 16\\)\\)",
        file("modules/control_plane/main.tf")
      )) == 1 &&
      length(regexall(
        "(?s)resource \"azurerm_container_app\" \"codexproxy\" \\{.*?env \\{\\s*name\\s*=\\s*\"PROXY_KEY_VERSION\"\\s*value\\s*=\\s*local.proxy_key_revision\\s*\\}",
        file("modules/control_plane/main.tf")
      )) == 1 &&
      length(regexall(
        "(?s)resource \"azurerm_container_app\" \"searchmcp\" \\{.*?env \\{\\s*name\\s*=\\s*\"PROXY_KEY_VERSION\"\\s*value\\s*=\\s*local.proxy_key_revision\\s*\\}",
        file("modules/control_plane/main.tf")
      )) == 1
    )
    error_message = "Both sidecars must reference PROXY_KEY as a Container App secret and include a non-secret revision marker so key rotation restarts them."
  }
}

run "existing_foundry_project_is_reused_read_only" {
  command = plan

  override_data {
    target          = module.foundry.data.azurerm_cognitive_account.existing[0]
    override_during = plan

    values = {
      id                            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-existing-eus2/providers/Microsoft.CognitiveServices/accounts/foundry-account-live"
      name                          = "foundry-account-live"
      endpoint                      = "https://custom-subdomain.cognitiveservices.azure.com/"
      local_auth_enabled            = false
      project_management_enabled    = true
      public_network_access_enabled = false
    }
  }

  override_data {
    target          = module.foundry.data.azapi_resource.existing_project[0]
    override_during = plan

    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-existing-eus2/providers/Microsoft.CognitiveServices/accounts/foundry-account-live/projects/reusedproj"
    }
  }

  variables {
    location              = "eastus2"
    owner                 = "test@example.com"
    cost_center           = "TEST"
    apim_publisher_name   = "Test"
    apim_publisher_email  = "test@example.com"
    budget_alert_email    = "test@example.com"
    budget_start_date     = "2026-07-01T00:00:00Z"
    reuse_foundry         = true
    reuse_foundry_project = true
    existing_foundry_name = "foundry-account-live"
    existing_foundry_rg   = "rg-existing-eus2"
    foundry_project_name  = "reusedproj"
    codexproxy_image      = ""
    searchmcp_image       = ""
  }

  assert {
    condition     = module.foundry.project_responses_base == "https://custom-subdomain.services.ai.azure.com/api/projects/reusedproj/openai/v1"
    error_message = "The root module must pass existing-project reuse through to the Foundry module."
  }

  assert {
    condition = (
      var.reuse_foundry_project &&
      length(regexall(
        "reuse_existing_project\\s*=\\s*var\\.reuse_foundry_project",
        file("main.tf")
      )) == 1
    )
    error_message = "The root module must wire reuse_foundry_project to the Foundry module."
  }
}

run "existing_project_reuse_requires_account_reuse" {
  command = plan

  variables {
    location              = "eastus2"
    owner                 = "test@example.com"
    cost_center           = "TEST"
    apim_publisher_name   = "Test"
    apim_publisher_email  = "test@example.com"
    budget_alert_email    = "test@example.com"
    budget_start_date     = "2026-07-01T00:00:00Z"
    reuse_foundry_project = true
    codexproxy_image      = ""
    searchmcp_image       = ""
  }

  expect_failures = [var.reuse_foundry_project]
}
