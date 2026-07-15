mock_provider "azurerm" {}
mock_provider "azapi" {}

run "native_responses_models_must_be_allowed" {
  command = plan

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
    public              = true

    model_account_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/aisproj-test"
    model_openai_v1_base = "https://aisproj-test.openai.azure.com/openai/v1"
    policy_template_path = "../../../policies/inference-pipeline.xml.tftpl"

    appinsights_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Insights/components/appi-test"
    appinsights_connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000"
    tokens_per_minute             = 150000
    model_tokens_per_minute       = { "gpt-5.6-sol" = 500000 }
    token_quota                   = 30000000
    token_quota_period            = "Daily"
    allowed_model_names           = ["gpt-5.6-sol"]
    native_responses_models       = ["not-deployed"]
    rate_tiers = {
      small = { tpm = 50000, quota = 5000000, period = "Daily" }
    }
    client_auth_mode   = "subscription-key"
    entra_tenant_id    = ""
    entra_api_audience = ""
    entra_team_claim   = "groups"
  }

  expect_failures = [var.native_responses_models]
}
