mock_provider "azurerm" {}
mock_provider "azapi" {}

variables {
  name_suffix         = "aigw-test-eus2"
  resource_group_name = "rg-aigw-test-eus2"
  location            = "eastus2"
  tags                = { env = "test" }
  sku_name            = "Developer_1"
  publisher_name      = "Test"
  publisher_email     = "test@example.com"
  apim_subnet_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-apim"
  public_ip_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/publicIPAddresses/pip-apim"

  openai_account_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/oai-test"
  openai_endpoint    = "https://oai-test.openai.azure.com"
  foundry_account_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/ais-test"
  foundry_endpoint   = "https://ais-test.openai.azure.com/openai/v1"

  openai_aliases     = ["gpt-5.4", "gpt-5.4-mini"]
  foundry_aliases    = ["grok-4.3", "DeepSeek-V4-Pro"]
  openai_path_base   = "https://oai-test.openai.azure.com/openai"
  foundry_v1_base    = "https://ais-test.openai.azure.com/openai/v1"
  openai_api_version = "2025-01-01-preview"

  policy_template_path         = "../../../policies/openai-pipeline.xml.tftpl"
  foundry_policy_template_path = "../../../policies/foundry-pipeline.xml.tftpl"
  openai_openapi_spec_url      = "https://example.com/openapi.json"

  appinsights_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Insights/components/appi-test"
  appinsights_connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000"

  tokens_per_minute = 150000
  model_tokens_per_minute = {
    "gpt-5.4"         = 200000
    "gpt-5.4-mini"    = 200000
    "grok-4.3"        = 10000
    "DeepSeek-V4-Pro" = 500000
  }
  token_quota        = 30000000
  token_quota_period = "Daily"
  allowed_models     = ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"]
  rate_tiers = {
    small  = { tpm = 50000, quota = 5000000, period = "Daily" }
    medium = { tpm = 150000, quota = 30000000, period = "Daily" }
    large  = { tpm = 300000, quota = 1000000000, period = "Monthly" }
  }

  client_auth_mode   = "subscription-key"
  entra_tenant_id    = ""
  entra_api_audience = ""
  entra_team_claim   = "groups"
}

run "model_tpm_fallback_contract" {
  command = plan

  assert {
    # NOTE: Terraform 1.15 requires assert conditions to reference at least one planned resource.
    # The `length(azurerm_api_management.apim.name) > 0` anchor satisfies this requirement without
    # changing any tested behavior (APIM name is always non-empty).
    condition = (
      strcontains(file("../../locals.tf"), "model_tokens_per_minute = merge(") &&
      strcontains(file("../../locals.tf"), "for model, deployment in var.openai_deployments") &&
      strcontains(file("../../locals.tf"), "for model, deployment in var.foundry_deployments") &&
      strcontains(file("../../main.tf"), "model_tokens_per_minute       = local.model_tokens_per_minute") &&
      length(azurerm_api_management.apim.name) > 0
    )
    error_message = "The root module must derive and pass one model TPM map from both deployment maps."
  }

  assert {
    condition = (
      length(regexall("(?s)effectiveDeployment\"\\] == \"gpt-5\\.4\"\\)'>\\s*<llm-token-limit[^>]*tokens-per-minute=\"200000\"", azurerm_api_management_api_policy.openai.xml_content)) == 1 &&
      length(regexall("(?s)effectiveDeployment\"\\] == \"grok-4\\.3\"\\)'>\\s*<llm-token-limit[^>]*tokens-per-minute=\"10000\"", azurerm_api_management_api_policy.openai.xml_content)) == 1 &&
      length(regexall("(?s)effectiveDeployment\"\\] == \"DeepSeek-V4-Pro\"\\)'>\\s*<llm-token-limit[^>]*tokens-per-minute=\"500000\"", azurerm_api_management_api_policy.vscode_openai.xml_content)) == 1
    )
    error_message = "OpenAI and VS Code policies must use the effective deployment's derived TPM when no tier applies."
  }

  assert {
    condition = (
      length(regexall("(?s)effectiveModel\"\\] == \"gpt-5\\.4-mini\"\\)'>\\s*<llm-token-limit[^>]*tokens-per-minute=\"200000\"", azurerm_api_management_api_policy.foundry.xml_content)) == 1 &&
      length(regexall("(?s)effectiveModel\"\\] == \"grok-4\\.3\"\\)'>\\s*<llm-token-limit[^>]*tokens-per-minute=\"10000\"", azurerm_api_management_api_policy.foundry.xml_content)) == 1 &&
      length(regexall("(?s)effectiveModel\"\\] == \"DeepSeek-V4-Pro\"\\)'>\\s*<llm-token-limit[^>]*tokens-per-minute=\"500000\"", azurerm_api_management_api_policy.foundry.xml_content)) == 1
    )
    error_message = "Foundry policy must use the effective model's derived TPM when no tier applies."
  }

  assert {
    condition = alltrue([
      for policy in [
        azurerm_api_management_api_policy.openai.xml_content,
        azurerm_api_management_api_policy.vscode_openai.xml_content,
        azurerm_api_management_api_policy.foundry.xml_content,
        ] : (
        length(regexall("(?s)effectiveTier\"\\] == \"small\"\\)'>\\s*<llm-token-limit[^>]*tier-small-tpm.*effectiveTier\"\\] == \"default\" &amp;&amp;", policy)) == 1 &&
        length(regexall("(?s)<otherwise>\\s*<llm-token-limit[^>]*tokens-per-minute=\"\\{\\{tokens-per-minute\\}\\}\"[^>]*token-quota=\"\\{\\{token-quota\\}\\}\"", policy)) >= 1
      )
    ])
    error_message = "Tier branches must precede model defaults, and unknown models must retain the global fallback."
  }
}

run "model_tpm_values_must_be_positive" {
  command = plan

  variables {
    model_tokens_per_minute = {
      "gpt-5.4" = 0
    }
  }

  expect_failures = [var.model_tokens_per_minute]
}

run "main_aligned_default_values" {
  command = plan

  assert {
    condition = (
      strcontains(file("../../variables.tf"), "default     = 150000") &&
      strcontains(file("../../variables.tf"), "default     = 30000000") &&
      strcontains(file("../../variables.tf"), "small  = { tpm = 50000, quota = 5000000, period = \"Daily\" }") &&
      strcontains(file("../../variables.tf"), "medium = { tpm = 150000, quota = 30000000, period = \"Daily\" }") &&
      strcontains(file("../../variables.tf"), "large  = { tpm = 300000, quota = 1000000000, period = \"Monthly\" }") &&
      length(azurerm_api_management.apim.name) > 0
    )
    error_message = "Terraform global and tier defaults must match main."
  }

  assert {
    condition = (
      length(regexall("\"gpt-5\\.4\"\\s*=\\s*\\{[^}]*capacity\\s*=\\s*500\\s*\\}", file("../../variables.tf"))) == 1 &&
      length(regexall("\"gpt-5\\.4-mini\"\\s*=\\s*\\{[^}]*capacity\\s*=\\s*500\\s*\\}", file("../../variables.tf"))) == 1 &&
      length(regexall("\"grok-4\\.3\"\\s*=\\s*\\{[^}]*capacity\\s*=\\s*500\\s*\\}", file("../../variables.tf"))) == 1 &&
      length(regexall("\"DeepSeek-V4-Pro\"\\s*=\\s*\\{[^}]*capacity\\s*=\\s*500\\s*\\}", file("../../variables.tf"))) == 1 &&
      length(azurerm_api_management.apim.name) > 0
    )
    error_message = "Every default OpenAI and Foundry deployment must use capacity 500."
  }

  assert {
    condition = (
      strcontains(file("../../../scripts/seed-config.sh"), "\"tokens_per_minute\": 150000") &&
      strcontains(file("../../../scripts/seed-config.sh"), "\"token_quota\": 30000000") &&
      strcontains(file("../../../scripts/seed-cosmos-jumpbox.sh"), "\"tokens_per_minute\": 150000") &&
      strcontains(file("../../../scripts/seed-cosmos-jumpbox.sh"), "\"token_quota\": 30000000") &&
      strcontains(file("../../../scripts/seed_cosmos.py"), "default=150000") &&
      strcontains(file("../../../scripts/seed_cosmos.py"), "default=30000000") &&
      length(azurerm_api_management.apim.name) > 0
    )
    error_message = "Every Cosmos global-config seed must use the main fallback values."
  }
}
