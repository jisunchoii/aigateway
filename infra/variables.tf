variable "prefix" {
  type        = string
  default     = "aigw"
  description = "Short workload prefix used in resource names (Microsoft's term for this pattern is 'AI gateway'). The live dev stack pins prefix=llmgw in terraform.tfvars; fresh deploys use this aigw default."
}

variable "env" {
  type        = string
  default     = "dev"
  description = "Environment short name (dev, test, prod)."
  validation {
    condition     = contains(["dev", "test", "prod"], var.env)
    error_message = "env must be one of: dev, test, prod."
  }
}

variable "location" {
  type        = string
  default     = "koreacentral"
  description = "Azure region. Keep all resources in one region (spec §resource layout)."
  validation {
    condition     = contains(["koreacentral", "koreasouth", "eastus", "eastus2", "westeurope"], var.location)
    error_message = "location must be one of the mapped regions (see region_short_map in locals.tf)."
  }
}

variable "owner" {
  type        = string
  description = "Owner tag value (email or team)."
}

variable "cost_center" {
  type        = string
  description = "costCenter tag value."
}

variable "apim_publisher_name" {
  type        = string
  description = "APIM publisher display name."
}

variable "apim_publisher_email" {
  type        = string
  description = "APIM publisher contact email."
}

variable "apim_sku_name" {
  type        = string
  default     = "Developer_1"
  description = "APIM SKU. Developer_1 supports internal VNet injection cheaply (no SLA). Override to Premium_1 for production."
}

variable "apim_public" {
  type        = bool
  default     = false
  description = "When true, APIM is published in EXTERNAL VNet mode (public gateway VIP) and the APIM NSG admits inbound HTTPS from the internet. Default false = Internal (VNet-only). Switching modes triggers a long-running APIM reconfiguration. Only expose publicly with edge protection (WAF/IP-filter), hardened auth, and tight rate/budget limits."
}

variable "monthly_budget_amount" {
  type        = number
  default     = 200
  description = "Monthly Cost Management budget (currency of the subscription). Demo guardrail."
  validation {
    condition     = var.monthly_budget_amount > 0
    error_message = "monthly_budget_amount must be a positive number."
  }
}

variable "budget_alert_email" {
  type        = string
  description = "Email to notify at budget thresholds."
  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}

variable "budget_start_date" {
  type        = string
  default     = "2026-06-01T00:00:00Z"
  description = "First-of-month UTC start date for the cost budget. Must not be in the past when first applied."
}

variable "openai_deployments" {
  type = map(object({
    model_name    = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  default = {
    "gpt-5.4" = {
      model_name    = "gpt-5.4"
      model_version = "2026-03-05"
      sku_name      = "GlobalStandard"
      capacity      = 10
    }
    "gpt-5.4-mini" = {
      model_name    = "gpt-5.4-mini"
      model_version = "2026-03-17"
      sku_name      = "GlobalStandard"
      capacity      = 10
    }
  }
  description = "Azure OpenAI deployments. Deployment name = real model name (no alias indirection); gpt-5.4-nano removed."
}

variable "foundry_deployments" {
  type = map(object({
    model_name    = string
    model_format  = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  # PAYG-first (GlobalStandard). PTU models (FW-Kimi-K2.6 / FW-GLM-5.1) deferred — large reserved
  # minimums. Kimi-K2.6 (PAYG) also deferred: 0 free quota in koreacentral (a bench deployment in
  # another RG holds the entire 100-unit limit). Capacities fit available quota (verified live
  # 2026-06): grok-4.3 has ~490 free; DeepSeek-V4-Pro catalog default is 5000 but only 500 is free,
  # and for GlobalStandard (PAYG) capacity is a TPM rate ceiling (not reserved cost), so 500 is safe.
  default = {
    "grok-4.3" = {
      model_name    = "grok-4.3"
      model_format  = "xAI"
      model_version = "1"
      sku_name      = "GlobalStandard"
      capacity      = 10
    }
    "DeepSeek-V4-Pro" = {
      model_name    = "DeepSeek-V4-Pro"
      model_format  = "DeepSeek"
      model_version = "2026-04-23"
      sku_name      = "GlobalStandard"
      capacity      = 500
    }
  }
  description = "Foundry OSS/partner model deployments on the AIServices account (PAYG GlobalStandard). Keys become client-facing aliases."
}

variable "reuse_foundry" {
  type        = bool
  default     = false
  description = "Brownfield: when true, reuse an EXISTING single AIServices (Foundry) account instead of creating one. The account + model deployments are read via a data source (not created); only the Private Endpoint and APIM RBAC are added. When true, the separate Azure OpenAI account is NOT created and gpt traffic is routed to the same AIServices account. The account must already have local_auth disabled and public network access blocked (see GitBook 04)."
}

variable "existing_foundry_name" {
  type        = string
  default     = ""
  description = "Name of the existing AIServices (Foundry) cognitive account to reuse. Required when reuse_foundry = true. Must be in the same subscription."
  validation {
    condition     = !var.reuse_foundry || length(var.existing_foundry_name) > 0
    error_message = "existing_foundry_name is required when reuse_foundry = true."
  }
}

variable "existing_foundry_rg" {
  type        = string
  default     = ""
  description = "Resource group of the existing AIServices account (may differ from the gateway RG; same subscription). Required when reuse_foundry = true."
  validation {
    condition     = !var.reuse_foundry || length(var.existing_foundry_rg) > 0
    error_message = "existing_foundry_rg is required when reuse_foundry = true."
  }
}

variable "enable_jumpbox" {
  type        = bool
  default     = false
  description = "Deploy the optional Bastion + jumpbox VM for in-VNet smoke testing."
}
variable "jumpbox_admin_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Admin password for the jumpbox VM. Required only when enable_jumpbox = true."
  validation {
    condition     = !var.enable_jumpbox || (var.jumpbox_admin_password != null && length(var.jumpbox_admin_password) >= 12)
    error_message = "jumpbox_admin_password is required (min 12 chars) when enable_jumpbox = true."
  }
}

variable "jumpbox_vm_size" {
  type        = string
  default     = "Standard_B2s_v2"
  description = "VM size for the jumpbox. Default B2s_v2 works in koreacentral; some regions restrict it (e.g. eastus2 -> use Standard_D2s_v7). Override per region in tfvars."
}

variable "openai_api_version" {
  type        = string
  default     = "2025-01-01-preview"
  description = "Azure OpenAI data-plane REST API version that CLIENTS send as ?api-version= (e.g. smoke-test scripts). Phase 1 APIM passes it through and does not enforce it in-gateway; a later phase may pin it via a set-query-parameter policy. Not consumed by Terraform resources today."
}

variable "openai_openapi_spec_url" {
  type        = string
  default     = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"
  description = "URL of the Azure OpenAI inference OpenAPI spec imported into APIM to create API operations (chat/completions, embeddings, etc)."
}

variable "tokens_per_minute" {
  type        = number
  default     = 150000
  description = "Fallback per-consumer token-per-minute limit enforced by llm-token-limit when no tier/model-derived limit applies."
  validation {
    condition     = var.tokens_per_minute > 0
    error_message = "tokens_per_minute must be a positive number."
  }
}

variable "token_quota" {
  type        = number
  default     = 30000000
  description = "Per-team token quota per quota period (llm-token-limit)."
  validation {
    condition     = var.token_quota > 0
    error_message = "token_quota must be a positive number."
  }
}

variable "token_quota_period" {
  type        = string
  default     = "Daily"
  description = "Reset period for token_quota: Hourly | Daily | Weekly | Monthly | Yearly."
  validation {
    condition     = contains(["Hourly", "Daily", "Weekly", "Monthly", "Yearly"], var.token_quota_period)
    error_message = "token_quota_period must be one of: Hourly, Daily, Weekly, Monthly, Yearly."
  }
}

variable "allowed_models" {
  type        = list(string)
  default     = ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"]
  description = "Model deployment names callers are allowed to request (OpenAI + Foundry OSS). A request for any other deployment returns 403."
  validation {
    condition     = alltrue([for m in var.allowed_models : m == trimspace(m) && length(m) > 0])
    error_message = "allowed_models entries must be non-empty and have no leading/trailing whitespace."
  }
}

variable "client_auth_mode" {
  type        = string
  default     = "subscription-key"
  description = "Client->gateway auth: 'subscription-key' (default, works today) or 'entra-id' (validate-jwt). Keep subscription-key until Entra ID is proven, then flip."
  validation {
    condition     = contains(["subscription-key", "entra-id"], var.client_auth_mode)
    error_message = "client_auth_mode must be 'subscription-key' or 'entra-id'."
  }
}

variable "entra_tenant_id" {
  type        = string
  default     = ""
  description = "Entra ID tenant (GUID or domain) for the validate-jwt openid-config URL. Required when client_auth_mode = entra-id."
}

variable "entra_api_audience" {
  type        = string
  default     = ""
  description = "Expected 'aud' claim (the gateway app registration's Application ID URI or client ID). Required when client_auth_mode = entra-id."
}

variable "entra_team_claim" {
  type        = string
  default     = "groups"
  description = "JWT claim used to derive teamId in entra-id mode. NOTE: the 'groups' claim returns object-ID GUIDs (opaque in dashboards) and is OMITTED entirely for users in >150 groups (those callers collapse to 'unknown-team' and share one rate-limit bucket). For production prefer a single-valued custom app-role or extension-attribute claim. The claim name is interpolated into a policy expression, so it must be a simple identifier."
  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+$", var.entra_team_claim))
    error_message = "entra_team_claim must contain only letters, digits, dots, underscores, or hyphens (it is interpolated into an APIM policy expression)."
  }
}

variable "worker_image" {
  type        = string
  default     = ""
  description = "Full image reference for the config-sync worker (e.g. acrllmgwxxxx.azurecr.io/config-sync:latest). Empty until the image is built+pushed; the job is created only when set."
}

variable "config_sync_cron" {
  type        = string
  default     = "*/5 * * * *"
  description = "UTC cron (5 fields) for the config-sync job. Default: every 5 minutes."
}

variable "admin_ui_image" {
  type        = string
  default     = ""
  description = "Full image reference for the Admin UI (SPA+BFF), e.g. acrllmgwxxxx.azurecr.io/admin-ui:latest. Empty until built+pushed; the Container App is created only when set."
}

variable "admin_ui_public" {
  type        = bool
  default     = false
  description = "When true, the Container Apps environment is created EXTERNAL so the Admin UI gets a public FQDN (still gated by Entra OIDC + admin-group). Default false = internal (VNet-only). Immutable after env creation — flipping recreates the env + Admin UI app, so set it at first deploy of a stack."
}

variable "bff_api_audience" {
  type        = string
  default     = ""
  description = "Expected 'aud' for the Admin UI BFF (api://<bff app id> from manual prereq P2). Required when admin_ui_image is set."
}

variable "spa_client_id" {
  type        = string
  default     = ""
  description = "Admin UI SPA (public client) app registration client id (prereq P3). Served to the browser via /api/config."
}

variable "admin_group_object_id" {
  type        = string
  default     = ""
  description = "Entra ID security group object id whose members are gateway admins (prereq P1). The BFF gates writes on membership."
}

variable "enable_codexproxy" {
  type        = bool
  default     = false
  description = "Master toggle for the Codex proxy sidecar: the project-enabled Foundry account, its deployments, the identity/hop-key/RBAC, and the Container App. When false, none are created and /responses stays on its current backend."
}

variable "project_deployments" {
  type = map(object({
    model_name    = string
    model_format  = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  default = {
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
  description = "Model deployments on the project-enabled account fronted by the Codex proxy sidecar. Includes the sidecar's models (GLM, DeepSeek) plus every downgrade-ladder target that could arrive via APIM downgrade, so a rewritten model always resolves. gpt-5.4/mini stay on the OpenAI path (openai module) and are NOT deployed here — a consumer whose ladder downgrades a sidecar model down to gpt-5.4 would 404 at the sidecar; this plan's scope is sidecar models (GLM/DeepSeek) whose ladders stay within Foundry models (-> grok-4.3)."
}

variable "rate_tiers" {
  type = map(object({ tpm = number, quota = number, period = string }))
  default = {
    small  = { tpm = 50000, quota = 5000000, period = "Daily" }
    medium = { tpm = 150000, quota = 30000000, period = "Daily" }
    large  = { tpm = 300000, quota = 1000000000, period = "Monthly" }
  }
  description = "Per-team rate-limit tiers. Single source feeding APIM tier named values (policy enforcement) and the Admin UI RATE_TIERS_JSON env (display)."
  validation {
    condition = length(var.rate_tiers) > 0 && !contains(keys(var.rate_tiers), "default") && alltrue([
      for t in values(var.rate_tiers) :
      contains(["Hourly", "Daily", "Weekly", "Monthly"], t.period) && t.tpm > 0 && t.quota > 0
    ])
    error_message = "rate_tiers must be non-empty, must not use the reserved key 'default', and each tier needs tpm>0, quota>0, period in Hourly/Daily/Weekly/Monthly."
  }
}
