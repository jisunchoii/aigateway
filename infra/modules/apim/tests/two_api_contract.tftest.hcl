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
    rate_tiers = {
      small  = { tpm = 50000, quota = 5000000, period = "Daily" }
      medium = { tpm = 150000, quota = 30000000, period = "Daily" }
      large  = { tpm = 300000, quota = 1000000000, period = "Monthly" }
    }
    client_auth_mode   = "subscription-key"
    entra_tenant_id    = ""
    entra_api_audience = ""
    entra_team_claim   = "groups"

    codexproxy_enabled  = true
    codexproxy_base_url = "https://codexproxy.example"
    codexproxy_key      = "sk-test-hop-key"
    searchmcp_enabled   = true
    searchmcp_base_url  = "https://searchmcp.example"
    native_responses_models = [
      "gpt-5.6-sol",
      "grok-4.3",
    ]
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
      search_mcp = {
        name        = "search-mcp"
        path        = "mcp"
        header      = "api-key"
        service_url = "https://searchmcp.example"
        operations = {
          mcp = {
            method       = "POST"
            url_template = "/"
            policy = {
              authorization_header    = "Bearer {{codexproxy-key}}"
              buffer_response         = false
              remove_headers          = ["api-key", "Ocp-Apim-Subscription-Key"]
              remove_query_parameters = ["subscription-key"]
              rewrite_uri             = "/mcp"
            }
          }
        }
      }
    }
    error_message = "APIM must expose the approved APIs, operations, and Search MCP forwarding contract."
  }

  assert {
    condition = (
      azurerm_api_management_api.model_gateway.subscription_key_parameter_names[0].header == "api-key" &&
      azurerm_api_management_api.vscode_models.subscription_key_parameter_names[0].header == "Ocp-Apim-Subscription-Key" &&
      azurerm_api_management_api.search_mcp[0].subscription_key_parameter_names[0].header == "api-key"
    )
    error_message = "The APIs must validate the same APIM key under their client-specific header names."
  }

  assert {
    condition = (
      azurerm_api_management_api_operation.model_gateway_chat.url_template == "/chat/completions" &&
      azurerm_api_management_api_operation.model_gateway_responses.url_template == "/responses" &&
      azurerm_api_management_api_operation.vscode_chat.url_template == "/deployments/{model}/chat/completions" &&
      azurerm_api_management_api.search_mcp[0].service_url == "https://searchmcp.example" &&
      azurerm_api_management_api_operation.search_mcp[0].method == "POST" &&
      azurerm_api_management_api_operation.search_mcp[0].url_template == "/"
    )
    error_message = "No wildcard or imported operations may remain."
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
        strcontains(policy, "<llm-emit-token-metric") &&
        !strcontains(policy, "gptFamily") &&
        !strcontains(policy, "legacy_gpt")
      )
    ])
    error_message = "Both APIs must use the same strict validation/governance policy without compatibility logic."
  }

  assert {
    condition = alltrue([
      for policy in [output.rendered_policy_xml.model_gateway, output.rendered_policy_xml.vscode_models] : (
        strcontains(policy, "if (effective == \"FW-GLM-5.2\")") &&
        strcontains(policy, "refusal.Type == Newtonsoft.Json.Linq.JTokenType.Null") &&
        strcontains(policy, "message.Remove(\"refusal\");")
      )
    ])
    error_message = "Both APIs must remove only null refusal fields when routing to FW-GLM-5.2."
  }

  assert {
    condition = alltrue([
      for policy in [output.rendered_policy_xml.model_gateway, output.rendered_policy_xml.vscode_models] : (
        strcontains(policy, "context.Operation.Id == \"responses\"") &&
        strcontains(policy, "item[\"type\"] == null") &&
        strcontains(policy, "item[\"type\"] = \"message\";")
      )
    ])
    error_message = "Responses requests must normalize role/content input messages for Azure Responses compatibility."
  }

  assert {
    condition = (
      length(regexall("subscription-key", jsonencode([
        output.rendered_policy_xml.model_gateway,
        output.rendered_policy_xml.vscode_models,
      ]))) == 2 &&
      length(regexall("<set-query-parameter name=\"subscription-key\" exists-action=\"delete\" />", file("../../../policies/inference-pipeline.xml.tftpl"))) == 1 &&
      length(regexall("(?s)<set-header name=\"api-key\" exists-action=\"delete\" />.*<set-header name=\"Ocp-Apim-Subscription-Key\" exists-action=\"delete\" />.*<set-query-parameter name=\"subscription-key\" exists-action=\"delete\" />.*<set-backend-service", file("../../../policies/inference-pipeline.xml.tftpl"))) == 1
    )
    error_message = "Both rendered policies must delete subscription-key exactly once before backend routing/auth begins."
  }

  assert {
    condition = alltrue([
      for policy in [output.rendered_policy_xml.model_gateway, output.rendered_policy_xml.vscode_models] : (
        length(regexall("var deployed = new\\[\\] \\{ \"DeepSeek-V4-Pro\", \"FW-GLM-5\\.2\", \"gpt-5\\.6-sol\", \"grok-4\\.3\" \\};", policy)) == 2 &&
        length(regexall("tier == \"(large|medium|small)\"", policy)) == 3 &&
        !strcontains(policy, "&quot;") &&
        strcontains(policy, "value='@{") &&
        !strcontains(policy, "value=\"@{") &&
        !strcontains(policy, ".Split(',')")
      )
    ])
    error_message = "APIM policy expressions must keep raw C# quotes inside well-formed single-quoted XML attributes."
  }

  assert {
    condition = (
      azurerm_api_management_api.model_gateway.name != "" &&
      strcontains(file("main.tf"), "resource \"terraform_data\" \"model_gateway_policy_hash\"") &&
      strcontains(file("main.tf"), "resource \"terraform_data\" \"vscode_models_policy_hash\"") &&
      strcontains(file("main.tf"), "resource \"terraform_data\" \"search_mcp_policy_hash\"") &&
      strcontains(file("main.tf"), "replace_triggered_by = [terraform_data.model_gateway_policy_hash]") &&
      strcontains(file("main.tf"), "replace_triggered_by = [terraform_data.vscode_models_policy_hash]") &&
      strcontains(file("main.tf"), "replace_triggered_by = [terraform_data.search_mcp_policy_hash[0]]") &&
      length(regexall("ignore_changes\\s*=\\s*\\[xml_content\\]", file("main.tf"))) == 3
    )
    error_message = "Policy formatting drift must be ignored while content hashes still force intentional policy replacement for all APIM policies."
  }

  assert {
    condition = (
      strcontains(output.rendered_policy_xml.model_gateway, "context.Operation.Id == \"responses\"") &&
      strcontains(
        output.rendered_policy_xml.model_gateway,
        "new string[] { \"gpt-5.6-sol\", \"grok-4.3\" }.Contains((string)context.Variables[\"effectiveModel\"])"
      ) &&
      !strcontains(
        output.rendered_policy_xml.model_gateway,
        "'@((string)context.Variables[\"effectiveModel\"] == \"gpt-5.6-sol\")'"
      ) &&
      strcontains(output.rendered_policy_xml.model_gateway, "base-url=\"https://codexproxy.example\"") &&
      strcontains(output.rendered_policy_xml.model_gateway, "{{codexproxy-key}}") &&
      strcontains(output.rendered_policy_xml.model_gateway, "resource=\"https://cognitiveservices.azure.com\"") &&
      strcontains(output.rendered_policy_xml.model_gateway, "buffer-response=\"false\"") &&
      strcontains(output.rendered_policy_xml.vscode_models, "context.Request.MatchedParameters.GetValueOrDefault(\"model\", \"\")") &&
      strcontains(output.rendered_policy_xml.vscode_models, "<rewrite-uri template=\"/chat/completions\" copy-unmatched-params=\"false\"")
    )
    error_message = "Model Gateway Responses must send GPT directly to Foundry and only non-GPT models to the sidecar; VS Code must convert its path model to v1 body routing."
  }

  assert {
    condition = (
      strcontains(output.rendered_policy_xml.search_mcp, "<rewrite-uri template=\"/mcp\"") &&
      strcontains(output.rendered_policy_xml.search_mcp, "<set-header name=\"Authorization\" exists-action=\"override\">") &&
      strcontains(output.rendered_policy_xml.search_mcp, "@(\"Bearer \" + \"{{codexproxy-key}}\")") &&
      strcontains(output.rendered_policy_xml.search_mcp, "<set-header name=\"api-key\" exists-action=\"delete\" />") &&
      strcontains(output.rendered_policy_xml.search_mcp, "<set-header name=\"Ocp-Apim-Subscription-Key\" exists-action=\"delete\" />") &&
      strcontains(output.rendered_policy_xml.search_mcp, "<set-query-parameter name=\"subscription-key\" exists-action=\"delete\" />") &&
      strcontains(output.rendered_policy_xml.search_mcp, "<forward-request timeout=\"300\" fail-on-error-status-code=\"false\" buffer-response=\"false\" />")
    )
    error_message = "Search MCP must rewrite / to /mcp, inject Bearer {{codexproxy-key}}, scrub client keys, and stream responses."
  }
}

run "responses_bootstrap_without_image" {
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
    rate_tiers = {
      small = { tpm = 50000, quota = 5000000, period = "Daily" }
    }
    client_auth_mode        = "subscription-key"
    entra_tenant_id         = ""
    entra_api_audience      = ""
    entra_team_claim        = "groups"
    codexproxy_enabled      = false
    codexproxy_base_url     = ""
    codexproxy_key          = ""
    searchmcp_enabled       = false
    searchmcp_base_url      = ""
    native_responses_models = ["gpt-5.6-sol"]
  }

  assert {
    condition = (
      output.codexproxy_contract.named_value_count == 0 &&
      output.api_contract.search_mcp == null &&
      output.rendered_policy_xml.search_mcp == null &&
      strcontains(
        output.rendered_policy_xml.model_gateway,
        "new string[] { \"gpt-5.6-sol\" }.Contains((string)context.Variables[\"effectiveModel\"])"
      ) &&
      strcontains(output.rendered_policy_xml.model_gateway, "code=\"503\"") &&
      !strcontains(output.rendered_policy_xml.model_gateway, "{{codexproxy-key}}")
    )
    error_message = "The first apply must keep Chat usable and fail Responses explicitly until an image is configured."
  }
}
