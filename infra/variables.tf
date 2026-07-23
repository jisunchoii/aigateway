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

variable "model_deployments" {
  type = map(object({
    model_name    = string
    model_format  = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  default = {
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
      capacity      = 500
    }
  }
  description = "Supported model deployment map. In new-deployment mode Terraform creates these deployments; in reuse mode they describe the deployments that must already exist."

  validation {
    condition = alltrue([
      for name, deployment in var.model_deployments :
      name == deployment.model_name && deployment.capacity > 0
    ])
    error_message = "Each deployment key must equal model_name and capacity must be positive."
  }
}

variable "native_responses_models" {
  type        = set(string)
  default     = ["gpt-5.6-sol"]
  description = "Deployments verified to accept Responses API requests directly through Foundry."

  validation {
    condition     = length(setsubtract(var.native_responses_models, toset(keys(var.model_deployments)))) == 0
    error_message = "native_responses_models must be a subset of model_deployments."
  }
}

variable "reuse_foundry" {
  type        = bool
  default     = false
  description = "When false, create and manage the AIServices account, project, and model deployments. When true, read an existing account and leave its model deployments unmanaged."
}

variable "reuse_foundry_project" {
  type        = bool
  default     = false
  description = "When true, read the existing Foundry project without managing its lifecycle. Requires reuse_foundry = true."

  validation {
    condition     = !var.reuse_foundry_project || var.reuse_foundry
    error_message = "reuse_foundry_project requires reuse_foundry = true."
  }
}

variable "existing_foundry_name" {
  type        = string
  default     = ""
  description = "Exact name of the existing AIServices account selected for reuse. Required when reuse_foundry = true; verify the full resource ID rather than matching by name alone."
  validation {
    condition     = !var.reuse_foundry || length(var.existing_foundry_name) > 0
    error_message = "existing_foundry_name is required when reuse_foundry = true."
  }
}

variable "existing_foundry_rg" {
  type        = string
  default     = ""
  description = "Resource group of the existing AIServices account selected for reuse. Required when reuse_foundry = true; the account must be in the same subscription."
  validation {
    condition     = !var.reuse_foundry || length(var.existing_foundry_rg) > 0
    error_message = "existing_foundry_rg is required when reuse_foundry = true."
  }
}

variable "foundry_account_name" {
  type        = string
  default     = ""
  description = "Optional name for the AIServices account that Terraform creates and manages. Leave empty to use the generated name."
}

variable "foundry_project_name" {
  type        = string
  default     = "gatewayproj"
  description = "Foundry project name. Terraform creates and manages it unless reuse_foundry_project is true, in which case the existing project is read only."
}

variable "foundry_public_network_access_enabled" {
  type        = bool
  default     = false
  description = "Temporary private-endpoint validation option. Keep false for normal deployments."
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
    condition     = !var.enable_jumpbox || try(length(var.jumpbox_admin_password) >= 12, false)
    error_message = "jumpbox_admin_password is required (min 12 chars) when enable_jumpbox = true."
  }
}

variable "jumpbox_vm_size" {
  type        = string
  default     = "Standard_B2s_v2"
  description = "VM size for the jumpbox. Default B2s_v2 works in koreacentral; some regions restrict it (e.g. eastus2 -> use Standard_D2s_v7). Override per region in tfvars."
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
  description = "When admin_ui_image is set, true creates its dedicated Admin UI Container Apps environment with a public FQDN (still gated by Entra OIDC + admin group); false keeps that dedicated environment internal. It does not change the internal worker environment."
}

variable "admin_ui_aca_subnet_cidr" {
  type        = string
  default     = "10.40.5.32/27"
  description = "CIDR for the dedicated Admin UI Container Apps environment subnet. It must not overlap another VNet subnet and is delegated to Microsoft.App/environments."
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
