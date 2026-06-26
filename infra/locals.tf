# Deterministic per-deployment suffix reserved for child modules that need
# globally-unique names (Key Vault, Azure OpenAI custom subdomain, etc.).
# Intentionally unused at the root scope.
resource "random_string" "sfx" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  sfx = random_string.sfx.result

  # <type>-<workload>-<env>-<region> resource layout.
  region_short_map = {
    koreacentral = "krc"
    koreasouth   = "krs"
    eastus       = "eus"
    eastus2      = "eus2"
    westeurope   = "weu"
  }
  region_short = local.region_short_map[var.location]
  name_suffix  = "${var.prefix}-${var.env}-${local.region_short}"

  rg_name = "rg-${local.name_suffix}"

  tags = {
    env        = var.env
    workload   = var.prefix
    owner      = var.owner
    costCenter = var.cost_center
  }

  # gpt backend resolution: in reuse mode there is no separate Azure OpenAI account — gpt lives on
  # the same AIServices (Foundry) account, reached via its GA OpenAI/v1 route. In greenfield mode
  # gpt uses the dedicated Azure OpenAI account. Downstream (apim) consumes these, not the modules
  # directly, so the apim module signature is unchanged across both modes.
  gpt_backend_account_id = var.reuse_foundry ? module.foundry.id : module.openai[0].id
  gpt_backend_endpoint   = var.reuse_foundry ? module.foundry.endpoint_openai_host : module.openai[0].endpoint
  # Path base the policy appends "/deployments/{m}/chat/completions" or "/v1/chat/completions" to.
  # Reuse: the AIServices openai.azure.com host (…/openai). Greenfield: the OpenAI account (…/openai).
  gpt_backend_path_base = var.reuse_foundry ? "${module.foundry.endpoint_openai_host}/openai" : "${trimsuffix(module.openai[0].endpoint, "/")}/openai"
}
