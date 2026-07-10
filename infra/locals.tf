# Deterministic per-deployment suffix reserved for child modules that need
# globally-unique names (Key Vault, canonical AIServices custom subdomain, etc.).
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

  allowed_models = sort(keys(var.model_deployments))

  legacy_gpt_aliases = [
    "gpt-5.4",
    "gpt-5.4-mini",
  ]
  admin_ui_models = var.admin_ui_legacy_gpt_aliases_enabled ? sort(distinct(concat(
    local.allowed_models,
    local.legacy_gpt_aliases,
  ))) : local.allowed_models

  model_tokens_per_minute = {
    for model, deployment in var.model_deployments :
    model => deployment.capacity * 1000
  }

  codexproxy_enabled = var.codexproxy_image != ""
}
