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
    condition     = module.foundry.project_responses_base != null
    error_message = "A fresh deployment must create the project route."
  }
}
