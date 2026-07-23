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
    enable_jumpbox       = false
    worker_image         = ""
    admin_ui_image       = ""
    native_responses_models = [
      "gpt-5.6-sol",
    ]
    model_deployments = {
      "gpt-5.6-sol" = {
        model_name    = "gpt-5.6-sol"
        model_format  = "OpenAI"
        model_version = "2026-07-09"
        sku_name      = "GlobalStandard"
        capacity      = 500
      }
      "FW-GLM-5.2" = {
        model_name    = "FW-GLM-5.2"
        model_format  = "Fireworks"
        model_version = "1"
        sku_name      = "DataZoneStandard"
        capacity      = 500
      }
      "DeepSeek-V4-Pro" = {
        model_name    = "DeepSeek-V4-Pro"
        model_format  = "DeepSeek"
        model_version = "2026-04-23"
        sku_name      = "GlobalStandard"
        capacity      = 500
      }
      "grok-4.3" = {
        model_name    = "grok-4.3"
        model_format  = "xAI"
        model_version = "1"
        sku_name      = "GlobalStandard"
        capacity      = 500
      }
    }
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
      strcontains(module.apim.rendered_policy_xml.model_gateway, "new string[] { \"gpt-5.6-sol\" }.Contains((string)context.Variables[\"effectiveModel\"])") &&
      strcontains(module.apim.rendered_policy_xml.model_gateway, "Responses API is not enabled for the selected model")
    )
    error_message = "Responses must route only verified deployments directly and reject unsupported deployments explicitly."
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

run "native_responses_models_require_deployments" {
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
    enable_jumpbox       = false
    worker_image         = ""
    admin_ui_image       = ""

    native_responses_models = [
      "gpt-5.6-sol",
      "not-deployed",
    ]
  }

  expect_failures = [var.native_responses_models]
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
    enable_jumpbox        = false
    worker_image          = ""
    admin_ui_image        = ""
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
    enable_jumpbox        = false
    worker_image          = ""
    admin_ui_image        = ""
  }

  expect_failures = [var.reuse_foundry_project]
}

run "public_admin_ui_isolated_from_internal_worker" {
  command = plan

  override_resource {
    target          = module.network.azurerm_subnet.aca
    override_during = plan

    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-dev-eus2/providers/Microsoft.Network/virtualNetworks/vnet-aigw-dev-eus2/subnets/snet-aca"
    }
  }

  override_resource {
    target          = module.network.azurerm_subnet.aca_admin
    override_during = plan

    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-dev-eus2/providers/Microsoft.Network/virtualNetworks/vnet-aigw-dev-eus2/subnets/snet-aca-admin"
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
    admin_ui_image       = "example.azurecr.io/admin-ui:immutable"
    admin_ui_public      = true
    enable_jumpbox       = false
    worker_image         = ""
  }

  assert {
    condition = (
      module.control_plane.topology.internal.environment_name == "cae-${local.name_suffix}" &&
      module.control_plane.topology.internal.subnet_id == module.network.aca_subnet_id &&
      module.control_plane.topology.internal.internal_load_balancer_enabled &&
      module.control_plane.topology.admin_ui != null &&
      module.control_plane.topology.admin_ui.environment_name == "cae-admin-${local.name_suffix}" &&
      module.control_plane.topology.admin_ui.subnet_id == module.network.admin_ui_aca_subnet_id &&
      !module.control_plane.topology.admin_ui.internal_load_balancer_enabled &&
      module.control_plane.topology.internal.environment_name != module.control_plane.topology.admin_ui.environment_name &&
      module.control_plane.topology.internal.subnet_id != module.control_plane.topology.admin_ui.subnet_id
    )
    error_message = "A public Admin UI must use a distinct external CAE while worker workloads remain in the internal CAE."
  }
}
