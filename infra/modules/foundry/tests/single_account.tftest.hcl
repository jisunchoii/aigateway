mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "time" {}

override_resource {
  target          = azapi_resource.project_account[0]
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/ais-abc123"
  }
}

run "greenfield_single_account" {
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
    account_name                  = "ais-abc123"
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
    condition     = azapi_resource.project_account[0].body.properties.allowProjectManagement
    error_message = "The canonical account must support Foundry projects."
  }

  assert {
    condition     = azapi_resource.project_account[0].body.properties.publicNetworkAccess == "Disabled"
    error_message = "Fresh deployments must be private."
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
    error_message = "The canonical account must contain exactly the four supported deployments."
  }

  assert {
    condition     = azurerm_private_endpoint.project_account.private_service_connection[0].private_connection_resource_id == azapi_resource.project_account[0].id
    error_message = "The private endpoint must target the canonical account."
  }
}
