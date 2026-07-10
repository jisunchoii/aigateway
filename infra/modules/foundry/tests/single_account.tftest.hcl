mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "time" {}

override_resource {
  target          = azapi_resource.project_account[0]
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/aisproj-abc123"
  }
}

override_data {
  target          = data.azurerm_cognitive_account.existing[0]
  override_during = plan

  values = {
    id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-existing-eus2/providers/Microsoft.CognitiveServices/accounts/foundry-account-live"
    name               = "foundry-account-live"
    endpoint           = "https://custom-subdomain.cognitiveservices.azure.com/"
    local_auth_enabled = false
  }
}

run "greenfield_single_account_defaults" {
  command = plan

  variables {
    name_suffix         = "aigw-test-eus2"
    suffix              = "abc123"
    resource_group_name = "rg-aigw-test-eus2"
    location            = "eastus2"
    tags                = { env = "test" }
    pe_subnet_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-pe"
    dns_zone_ids = [
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com",
    ]
    project_name                  = "codexproj"
    public_network_access_enabled = false
    deployments = {
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
        capacity      = 10
      }
    }
  }

  assert {
    condition     = azapi_resource.project_account[0].name == "aisproj-abc123"
    error_message = "Empty account_name must default to aisproj-${var.suffix}."
  }

  assert {
    condition     = azapi_resource.project_account[0].body.properties.customSubDomainName == "aisproj-abc123"
    error_message = "The canonical custom subdomain must follow the managed account name."
  }

  assert {
    condition     = azapi_resource.project_account[0].body.properties.disableLocalAuth == true
    error_message = "disableLocalAuth must stay enabled for managed accounts."
  }

  assert {
    condition     = azapi_resource.project_account[0].body.properties.allowProjectManagement == true
    error_message = "Managed accounts must allow project management."
  }

  assert {
    condition     = azapi_resource.project_account[0].body.properties.networkAcls.defaultAction == "Deny"
    error_message = "Fresh deployments must deny public network ACLs by default."
  }

  assert {
    condition     = azapi_resource.project_account[0].body.properties.publicNetworkAccess == "Disabled"
    error_message = "Managed accounts must disable public network access."
  }

  assert {
    condition     = azapi_resource.project[0].parent_id == azapi_resource.project_account[0].id
    error_message = "The project must be a child of the canonical account."
  }

  assert {
    condition = toset(keys(azurerm_cognitive_deployment.project_models)) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "The canonical account must contain exactly the configured deployments."
  }

  assert {
    condition     = azurerm_private_endpoint.project_account.private_service_connection[0].private_connection_resource_id == azapi_resource.project_account[0].id
    error_message = "The private endpoint must target the canonical account."
  }

  assert {
    condition     = toset(azurerm_private_endpoint.project_account.private_service_connection[0].subresource_names) == toset(["account"])
    error_message = "The private endpoint must use the account subresource."
  }

  assert {
    condition = toset(azurerm_private_endpoint.project_account.private_dns_zone_group[0].private_dns_zone_ids) == toset([
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com",
    ])
    error_message = "The private endpoint must attach every configured Foundry DNS zone."
  }

  assert {
    condition     = output.id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/aisproj-abc123"
    error_message = "The id output must expose the canonical project-enabled account ID."
  }

  assert {
    condition     = output.name == "aisproj-abc123"
    error_message = "The name output must expose the canonical managed account name."
  }

  assert {
    condition     = output.endpoint == "https://aisproj-abc123.cognitiveservices.azure.com/"
    error_message = "The endpoint output must use the canonical cognitiveservices host."
  }

  assert {
    condition     = output.endpoint_openai_v1 == "https://aisproj-abc123.openai.azure.com/openai/v1"
    error_message = "The OpenAI/v1 output must use the canonical custom subdomain."
  }

  assert {
    condition     = output.endpoint_openai_host == "https://aisproj-abc123.openai.azure.com"
    error_message = "The OpenAI host output must use the canonical custom subdomain."
  }

  assert {
    condition     = output.project_account_id == output.id
    error_message = "project_account_id must remain a compatibility alias for id."
  }

  assert {
    condition = toset(output.deployment_names) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "deployment_names must expose the configured deployment catalog."
  }

  assert {
    condition     = output.project_responses_base == "https://aisproj-abc123.services.ai.azure.com/api/projects/codexproj/openai/v1"
    error_message = "The Responses base must use the canonical services.ai host."
  }
}

run "reuse_existing_account_uses_custom_subdomain" {
  command = plan

  variables {
    name_suffix         = "aigw-test-eus2"
    suffix              = "abc123"
    resource_group_name = "rg-aigw-test-eus2"
    location            = "eastus2"
    tags                = { env = "test" }
    pe_subnet_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-pe"
    dns_zone_ids = [
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com",
    ]
    reuse_existing        = true
    existing_account_name = "foundry-account-live"
    existing_account_rg   = "rg-existing-eus2"
    project_name          = "reusedproj"
    deployments = {
      "gpt-5.6-sol" = {
        model_name    = "gpt-5.6-sol"
        model_format  = "OpenAI"
        model_version = "2026-07-09"
        sku_name      = "GlobalStandard"
        capacity      = 500
      }
    }
  }

  assert {
    condition     = azapi_resource.project[0].parent_id == data.azurerm_cognitive_account.existing[0].id
    error_message = "Reuse mode must parent the project under the reused account ID."
  }

  assert {
    condition     = azurerm_private_endpoint.project_account.private_service_connection[0].private_connection_resource_id == data.azurerm_cognitive_account.existing[0].id
    error_message = "Reuse mode must target the reused account ID from the private endpoint."
  }

  assert {
    condition     = length(keys(azurerm_cognitive_deployment.project_models)) == 0
    error_message = "Reuse mode must not create deployments."
  }

  assert {
    condition     = output.id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-existing-eus2/providers/Microsoft.CognitiveServices/accounts/foundry-account-live"
    error_message = "Reuse mode must expose the reused account ID."
  }

  assert {
    condition     = output.project_account_id == output.id
    error_message = "project_account_id must still mirror id in reuse mode."
  }

  assert {
    condition     = toset(output.deployment_names) == toset(["gpt-5.6-sol"])
    error_message = "Reuse mode must keep deployment_names as the expected external catalog."
  }

  assert {
    condition     = output.name == "foundry-account-live"
    error_message = "The name output must preserve the reused Azure resource name."
  }

  assert {
    condition     = output.endpoint == "https://custom-subdomain.cognitiveservices.azure.com/"
    error_message = "The endpoint output must preserve the reused control endpoint."
  }

  assert {
    condition     = output.endpoint_openai_host == "https://custom-subdomain.openai.azure.com"
    error_message = "Reuse mode must derive the OpenAI host from the endpoint custom subdomain."
  }

  assert {
    condition     = output.endpoint_openai_v1 == "https://custom-subdomain.openai.azure.com/openai/v1"
    error_message = "Reuse mode must derive the OpenAI/v1 base from the endpoint custom subdomain."
  }

  assert {
    condition     = output.project_responses_base == "https://custom-subdomain.services.ai.azure.com/api/projects/reusedproj/openai/v1"
    error_message = "Reuse mode must derive the Responses base from the endpoint custom subdomain."
  }
}
