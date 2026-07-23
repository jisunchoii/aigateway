mock_provider "azurerm" {}
mock_provider "azapi" {}

run "two_api_contract" {
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
    model_tokens_per_minute = {
      "gpt-5.6-sol"     = 500000
      "FW-GLM-5.2"      = 500000
      "DeepSeek-V4-Pro" = 500000
      "grok-4.3"        = 10000
    }
    token_quota        = 30000000
    token_quota_period = "Daily"
    allowed_model_names = [
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ]
    native_responses_models = [
      "gpt-5.6-sol",
      "grok-4.3",
    ]
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

  assert {
    condition = output.api_contract == {
      model_gateway = {
        name   = "model-gateway"
        path   = "openai/v1"
        header = "api-key"
        operations = {
          chat      = "/chat/completions"
          responses = "/responses"
        }
      }
      vscode_models = {
        name   = "vscode-models"
        path   = "vscode/models"
        header = "Ocp-Apim-Subscription-Key"
        operations = {
          chat = "/deployments/{model}/chat/completions"
        }
      }
    }
    error_message = "APIM must expose only the approved model and VS Code APIs."
  }

  assert {
    condition = (
      azurerm_api_management_api.model_gateway.subscription_key_parameter_names[0].header == "api-key" &&
      azurerm_api_management_api.vscode_models.subscription_key_parameter_names[0].header == "Ocp-Apim-Subscription-Key" &&
      azurerm_api_management_api_operation.model_gateway_chat.url_template == "/chat/completions" &&
      azurerm_api_management_api_operation.model_gateway_responses.url_template == "/responses" &&
      azurerm_api_management_api_operation.vscode_chat.url_template == "/deployments/{model}/chat/completions"
    )
    error_message = "The two APIs must retain their client-specific headers and explicit operations."
  }

  assert {
    condition = alltrue([
      for policy in [output.rendered_policy_xml.model_gateway, output.rendered_policy_xml.vscode_models] : (
        strcontains(policy, "name=\"requestBodyValid\"") &&
        strcontains(policy, "code=\"400\"") &&
        strcontains(policy, "name=\"requestedModelAllowed\"") &&
        strcontains(policy, "deployed.Contains(requested)") &&
        strcontains(policy, "deployed.Contains(candidate) &amp;&amp; allowed.Contains(candidate)") &&
        strcontains(policy, "name=\"api-key\" exists-action=\"delete\"") &&
        strcontains(policy, "name=\"Ocp-Apim-Subscription-Key\" exists-action=\"delete\"") &&
        strcontains(policy, "<llm-token-limit") &&
        strcontains(policy, "<llm-emit-token-metric")
      )
    ])
    error_message = "Both APIs must use the same strict validation and governance policy."
  }

  assert {
    condition = (
      strcontains(
        output.rendered_policy_xml.model_gateway,
        "new string[] { \"gpt-5.6-sol\", \"grok-4.3\" }.Contains((string)context.Variables[\"effectiveModel\"])"
      ) &&
      strcontains(output.rendered_policy_xml.model_gateway, "resource=\"https://cognitiveservices.azure.com\"") &&
      strcontains(output.rendered_policy_xml.model_gateway, "Responses API is not enabled for the selected model") &&
      strcontains(output.rendered_policy_xml.vscode_models, "context.Request.MatchedParameters.GetValueOrDefault(\"model\", \"\")") &&
      strcontains(output.rendered_policy_xml.vscode_models, "<rewrite-uri template=\"/chat/completions\" copy-unmatched-params=\"false\"")
    )
    error_message = "Responses must route verified models directly to Foundry and reject other models; VS Code must convert path routing to the v1 body."
  }

  assert {
    condition = (
      azurerm_api_management_api.model_gateway.name != "" &&
      strcontains(file("main.tf"), "resource \"terraform_data\" \"model_gateway_policy_hash\"") &&
      strcontains(file("main.tf"), "resource \"terraform_data\" \"vscode_models_policy_hash\"") &&
      strcontains(file("main.tf"), "replace_triggered_by = [terraform_data.model_gateway_policy_hash]") &&
      strcontains(file("main.tf"), "replace_triggered_by = [terraform_data.vscode_models_policy_hash]") &&
      length(regexall("ignore_changes\\s*=\\s*\\[xml_content\\]", file("main.tf"))) == 2
    )
    error_message = "Intentional policy content changes must replace both APIM policies while formatting drift remains ignored."
  }
}

run "responses_rejects_unverified_models" {
  command = plan

  variables {
    name_suffix                   = "aigw-test-eus2"
    resource_group_name           = "rg-aigw-test-eus2"
    location                      = "eastus2"
    tags                          = { env = "test" }
    sku_name                      = "Developer_1"
    publisher_name                = "Test"
    publisher_email               = "test@example.com"
    apim_subnet_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-apim"
    public_ip_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/publicIPAddresses/pip-apim"
    model_account_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.CognitiveServices/accounts/aisproj-test"
    model_openai_v1_base          = "https://aisproj-test.openai.azure.com/openai/v1"
    policy_template_path          = "../../../policies/inference-pipeline.xml.tftpl"
    appinsights_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Insights/components/appi-test"
    appinsights_connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000"
    tokens_per_minute             = 150000
    model_tokens_per_minute = {
      "gpt-5.6-sol"     = 500000
      "FW-GLM-5.2"      = 500000
      "DeepSeek-V4-Pro" = 500000
      "grok-4.3"        = 10000
    }
    token_quota        = 30000000
    token_quota_period = "Daily"
    allowed_model_names = [
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ]
    native_responses_models = ["gpt-5.6-sol"]
    rate_tiers = {
      small = { tpm = 50000, quota = 5000000, period = "Daily" }
    }
    client_auth_mode   = "subscription-key"
    entra_tenant_id    = ""
    entra_api_audience = ""
    entra_team_claim   = "groups"
  }

  assert {
    condition = (
      strcontains(
        output.rendered_policy_xml.model_gateway,
        "new string[] { \"gpt-5.6-sol\" }.Contains((string)context.Variables[\"effectiveModel\"])"
      ) &&
      strcontains(output.rendered_policy_xml.model_gateway, "<set-status code=\"400\" reason=\"Bad Request\" />") &&
      strcontains(output.rendered_policy_xml.model_gateway, "Responses API is not enabled for the selected model")
    )
    error_message = "Unverified Responses models must fail explicitly without an alternate backend."
  }
}
