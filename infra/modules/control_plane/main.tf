variable "name_suffix" {
  type        = string
  description = "Naming suffix (workload-env-region) for resource names."
}
variable "resource_group_name" {
  type        = string
  description = "Resource group for control-plane resources."
}
variable "location" {
  type        = string
  description = "Azure region."
}
variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources."
}
variable "infra_subnet_id" {
  type        = string
  description = "Container Apps environment infrastructure subnet ID (delegated to Microsoft.App/environments)."
}
variable "law_id" {
  type        = string
  description = "Log Analytics workspace ID for the Container Apps environment."
}
variable "acr_id" {
  type        = string
  description = "ACR resource ID (for the worker and admin-ui AcrPull role assignments)."
}
variable "acr_login_server" {
  type        = string
  description = "ACR login server for the job's registry config."
}
variable "apim_id" {
  type        = string
  description = "APIM resource ID (for the worker and admin-ui API Management Service Contributor roles)."
}
variable "worker_identity_id" {
  type        = string
  description = "Resource ID of the worker user-assigned identity."
}
variable "worker_principal_id" {
  type        = string
  description = "Principal (object) ID of the worker identity (for RBAC)."
}
variable "worker_client_id" {
  type        = string
  description = "Client ID of the worker identity (AZURE_CLIENT_ID env for DefaultAzureCredential)."
}
variable "worker_image" {
  type        = string
  description = "Worker container image reference. Empty string disables the job."
}
variable "config_sync_cron" {
  type        = string
  description = "UTC cron for the scheduled job."
}
variable "cosmos_endpoint" {
  type        = string
  description = "Cosmos DB endpoint URL (worker env)."
}
variable "cosmos_database" {
  type        = string
  description = "Cosmos database name (worker env)."
}
variable "cosmos_container" {
  type        = string
  description = "Cosmos container name (worker env)."
}
variable "subscription_id" {
  type        = string
  description = "Azure subscription id (worker env)."
}
variable "apim_rg" {
  type        = string
  description = "APIM resource group (worker env)."
}
variable "apim_name" {
  type        = string
  description = "APIM service name (worker env)."
}
variable "vnet_id" {
  type        = string
  description = "VNet resource ID, for linking the Container Apps default-domain private DNS zone."
}

variable "admin_ui_image" {
  type        = string
  description = "Admin UI (SPA+BFF) container image reference. Empty string disables the app."
}

variable "admin_ui_identity_id" {
  type        = string
  description = "Resource ID of the BFF user-assigned identity (the control-plane WRITE identity)."
}

variable "admin_ui_principal_id" {
  type        = string
  description = "Principal (object) ID of the BFF identity (for APIM/ACR RBAC)."
}

variable "admin_ui_client_id" {
  type        = string
  description = "Client ID of the BFF identity (AZURE_CLIENT_ID for DefaultAzureCredential)."
}

variable "admin_ui_public" {
  type        = bool
  default     = false
  description = <<-EOT
    When false (default) the Container Apps environment is an internal ILB (vnetInternal=true):
    the Admin UI is reachable only from inside the VNet (jumpbox/VPN). When true the environment
    is created EXTERNAL (public virtual IP) so the Admin UI gets a public FQDN — still gated by the
    BFF's Entra OIDC + admin-group check. NOTE: internal<->external is immutable after env creation
    (MS Learn: container-apps/networking), so flipping this on an existing stack RECREATES the
    environment + Admin UI app. Outbound stays VNet-integrated (APIM/Cosmos reachable either way);
    only inbound becomes public. The in-VNet ACA private DNS zone is only needed for the internal
    case, so it's gated off when public (external envs get public DNS automatically).
  EOT
}

variable "entra_tenant_id" {
  type        = string
  description = "Entra ID tenant id (BFF token validation + SPA login)."
}

variable "bff_api_audience" {
  type        = string
  description = "Expected 'aud' for BFF token validation (api://<bff app id>)."
}

variable "spa_client_id" {
  type        = string
  description = "SPA (public client) app registration client id, served to the browser via /api/config."
}

variable "admin_group_object_id" {
  type        = string
  description = "Entra ID security group object id whose members are gateway admins."
}


variable "cosmos_map_container" {
  type        = string
  description = "Cosmos container name for team<->subscription mappings."
}

variable "rate_tiers_json" {
  type        = string
  description = "JSON of the rate-limit tiers (jsonencode of rate_tiers), surfaced to the BFF via RATE_TIERS_JSON for the rate-limit UI."
}

variable "alias_models_json" {
  type        = string
  description = "JSON of the deployment alias -> model name map (jsonencode of openai_deployments model_names), surfaced to the BFF via ALIAS_MODELS_JSON so the Models UI shows what each alias is."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Log Analytics workspace customerId (GUID) the BFF queries via azure-monitor-query for the Dashboard/Monitoring pages."
}

variable "litellm_image" {
  type        = string
  description = "LiteLLM Responses-bridge container image reference. Empty string disables the app."
  default     = ""
}

variable "litellm_identity_id" {
  type        = string
  description = "Resource ID of the LiteLLM user-assigned identity."
  default     = ""
}

variable "litellm_principal_id" {
  type        = string
  description = "Principal (object) ID of the LiteLLM identity (for ACR pull RBAC)."
  default     = ""
}

variable "litellm_client_id" {
  type        = string
  description = "Client ID of the LiteLLM identity (AZURE_CLIENT_ID for use_azure_ad backend auth)."
  default     = ""
}

variable "litellm_master_key" {
  type        = string
  sensitive   = true
  description = "Shared secret APIM presents to LiteLLM as 'Authorization: Bearer'. LiteLLM's master_key."
  default     = ""
}

variable "aoai_api_base" {
  type        = string
  description = "Azure OpenAI host base (https://<res>.openai.azure.com) for LiteLLM's gpt route."
  default     = ""
}

variable "foundry_api_base" {
  type        = string
  description = "Foundry OpenAI/v1 base (https://<res>.openai.azure.com/openai/v1) for LiteLLM's OSS routes."
  default     = ""
}

locals {
  worker_enabled   = var.worker_image != ""
  admin_ui_enabled = var.admin_ui_image != ""
  litellm_enabled  = var.litellm_image != ""
  # The in-VNet ACA private DNS zone + wildcard records are only needed to reach an INTERNAL env
  # by FQDN. An external (public) env gets public DNS automatically, so skip them when public.
  # Needed whenever an internal-reachable app (Admin UI or LiteLLM) is deployed.
  aca_private_dns_enabled = (local.admin_ui_enabled || local.litellm_enabled) && !var.admin_ui_public
}

resource "azurerm_role_assignment" "worker_acr_pull" {
  count                = local.worker_enabled ? 1 : 0
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = var.worker_principal_id
}

# NOTE: "API Management Service Contributor" is broader than the worker needs (it only writes
# named values). No built-in role is scoped to named-values-only; a custom role with
# Microsoft.ApiManagement/service/namedValues/{read,write} would be tighter. Tracked as future hardening.
resource "azurerm_role_assignment" "worker_apim" {
  count                = local.worker_enabled ? 1 : 0
  scope                = var.apim_id
  role_definition_name = "API Management Service Contributor"
  principal_id         = var.worker_principal_id
}

resource "azurerm_role_assignment" "admin_ui_acr_pull" {
  count                = local.admin_ui_enabled ? 1 : 0
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = var.admin_ui_principal_id
}

# NOTE: like the worker, this is broader than strictly needed (subscription CRUD only). A custom
# role scoped to Microsoft.ApiManagement/service/subscriptions/* would be tighter. Future hardening.
resource "azurerm_role_assignment" "admin_ui_apim" {
  count                = local.admin_ui_enabled ? 1 : 0
  scope                = var.apim_id
  role_definition_name = "API Management Service Contributor"
  principal_id         = var.admin_ui_principal_id
}

# The Admin UI BFF starts the config-sync job on a budget change (instant re-evaluation). Scoped to
# the job; "Container Apps Jobs Operator" grants start/stop only (not full contributor). Gated on
# both apps being deployed (the job only exists when the worker is enabled).
resource "azurerm_role_assignment" "admin_ui_start_job" {
  count                = local.admin_ui_enabled && local.worker_enabled ? 1 : 0
  scope                = azurerm_container_app_job.config_sync[0].id
  role_definition_name = "Container Apps Jobs Operator"
  principal_id         = var.admin_ui_principal_id
}

resource "azurerm_container_app_environment" "cp" {
  name                           = "cae-${var.name_suffix}"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  log_analytics_workspace_id     = var.law_id
  infrastructure_subnet_id       = var.infra_subnet_id
  internal_load_balancer_enabled = !var.admin_ui_public
  tags                           = var.tags
}

# Internal Container Apps env has no public DNS. To reach the BFF by FQDN from inside the VNet
# (jumpbox/VPN), Azure Private DNS needs a zone named EXACTLY the env default domain with a
# wildcard A record to the env static IP. (MS Learn: container-apps/private-endpoints-with-dns
# "Ingress for the virtual network scope".) Gated on the app existing.
resource "azurerm_private_dns_zone" "aca" {
  count               = local.aca_private_dns_enabled ? 1 : 0
  name                = azurerm_container_app_environment.cp.default_domain
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aca" {
  count                 = local.aca_private_dns_enabled ? 1 : 0
  name                  = "link-aca"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.aca[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# With external ingress on an internal ILB env, app FQDNs are <app>.<defaultDomain> (no
# ".internal." label), so a bare "*" wildcard (one label before the zone) matches. Both record
# names point at the env static IP; we keep "*" (covers external app FQDNs) and "*.internal"
# (covers env-internal app/label FQDNs) so any app in this env resolves to the ILB regardless
# of its ingress visibility.
resource "azurerm_private_dns_a_record" "aca_wildcard" {
  count               = local.aca_private_dns_enabled ? 1 : 0
  name                = "*"
  zone_name           = azurerm_private_dns_zone.aca[0].name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_container_app_environment.cp.static_ip_address]
  tags                = var.tags
}

resource "azurerm_private_dns_a_record" "aca_wildcard_internal" {
  count               = local.aca_private_dns_enabled ? 1 : 0
  name                = "*.internal"
  zone_name           = azurerm_private_dns_zone.aca[0].name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_container_app_environment.cp.static_ip_address]
  tags                = var.tags
}

resource "azurerm_container_app_job" "config_sync" {
  count                        = local.worker_enabled ? 1 : 0
  name                         = "job-config-sync-${var.name_suffix}"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.cp.id
  replica_timeout_in_seconds   = 300
  replica_retry_limit          = 1

  identity {
    type         = "UserAssigned"
    identity_ids = [var.worker_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.worker_identity_id
  }

  schedule_trigger_config {
    cron_expression          = var.config_sync_cron
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name   = "config-sync"
      image  = var.worker_image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "COSMOS_ENDPOINT"
        value = var.cosmos_endpoint
      }
      env {
        name  = "COSMOS_DATABASE"
        value = var.cosmos_database
      }
      env {
        name  = "COSMOS_CONTAINER"
        value = var.cosmos_container
      }
      env {
        name  = "SUBSCRIPTION_ID"
        value = var.subscription_id
      }
      env {
        name  = "APIM_RG"
        value = var.apim_rg
      }
      env {
        name  = "APIM_NAME"
        value = var.apim_name
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = var.worker_client_id
      }
      env {
        name  = "LOG_ANALYTICS_WORKSPACE_ID"
        value = var.log_analytics_workspace_id
      }
    }
  }
}

resource "azurerm_container_app" "admin_ui" {
  count                        = local.admin_ui_enabled ? 1 : 0
  name                         = "ca-adminui-${var.name_suffix}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.cp.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [var.admin_ui_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.admin_ui_identity_id
  }

  ingress {
    # external_enabled = true is required so the app is reachable from elsewhere in the VNet
    # (jumpbox/VPN), NOT just from inside the Container Apps environment. Because the
    # environment itself is an internal ILB env (vnetInternal=true, no public IP), "external"
    # here means "exposed on the environment's internal load balancer (10.40.x)" — it is NOT
    # public-internet exposed. With external_enabled=false the app gets an <app>.internal.<env>
    # FQDN that the edge proxy 404s for any caller outside the environment (MS Learn:
    # container-apps/connect-apps — "requests from outside the environment receive a 404").
    external_enabled = true
    target_port      = 8000
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Keep one warm replica. The default (min 0) scales the app to zero with no HTTP wake
    # rule, so the internal LB returns 404 "Container App is stopped" on the first request.
    # An on-demand internal admin tool needs a floor of 1 to avoid cold-start 404s.
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "admin-ui"
      image  = var.admin_ui_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "ENTRA_TENANT_ID"
        value = var.entra_tenant_id
      }
      env {
        name  = "BFF_API_AUDIENCE"
        value = var.bff_api_audience
      }
      env {
        name  = "SPA_CLIENT_ID"
        value = var.spa_client_id
      }
      env {
        name  = "ADMIN_GROUP_OBJECT_ID"
        value = var.admin_group_object_id
      }
      env {
        name  = "SUBSCRIPTION_ID"
        value = var.subscription_id
      }
      env {
        name  = "APIM_RG"
        value = var.apim_rg
      }
      env {
        name  = "APIM_NAME"
        value = var.apim_name
      }
      env {
        name  = "COSMOS_ENDPOINT"
        value = var.cosmos_endpoint
      }
      env {
        name  = "COSMOS_DATABASE"
        value = var.cosmos_database
      }
      env {
        name  = "COSMOS_MAP_CONTAINER"
        value = var.cosmos_map_container
      }
      env {
        name  = "RATE_TIERS_JSON"
        value = var.rate_tiers_json
      }
      env {
        name  = "ALIAS_MODELS_JSON"
        value = var.alias_models_json
      }
      env {
        name  = "LOG_ANALYTICS_WORKSPACE_ID"
        value = var.log_analytics_workspace_id
      }
      # The config-sync job the BFF starts on a budget change (instant re-eval). Empty when the
      # worker isn't deployed — JobStarter no-ops on an empty name.
      env {
        name  = "CONFIG_SYNC_JOB_NAME"
        value = local.worker_enabled ? "job-config-sync-${var.name_suffix}" : ""
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = var.admin_ui_client_id
      }
    }
  }
}

# LiteLLM pulls its image from ACR with its own identity.
resource "azurerm_role_assignment" "litellm_acr_pull" {
  count                = local.litellm_enabled ? 1 : 0
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = var.litellm_principal_id
}

# LiteLLM Responses bridge. Same CAE as the Admin UI; internal ingress on port 4000. APIM's
# /responses API routes here and authenticates with the master key. LiteLLM itself calls the
# Azure OpenAI + Foundry backends with its managed identity (use_azure_ad), no keys.
# ponytail: follows the env's public/internal toggle (admin_ui_public); when external it gets a
# public FQDN but stays gated by master_key. Split the env if LiteLLM must be internal-only.
resource "azurerm_container_app" "litellm" {
  count                        = local.litellm_enabled ? 1 : 0
  name                         = "ca-litellm-${var.name_suffix}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.cp.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [var.litellm_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.litellm_identity_id
  }

  ingress {
    # external_enabled=true = reachable on the env load balancer (internal ILB when
    # admin_ui_public=false), NOT necessarily public internet. APIM (VNet-injected) reaches it here.
    external_enabled = true
    target_port      = 4000
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "litellm"
      image  = var.litellm_image
      cpu    = 1.0
      memory = "2Gi"

      # LiteLLM takes tens of seconds to import providers and bind :4000. The default startup probe
      # (few retries at 1s) kills it (exit 137) before the port opens. Give it a generous TCP
      # startup window: up to 60 * 5s = 5 min before the platform considers startup failed.
      startup_probe {
        transport               = "TCP"
        port                    = 4000
        initial_delay           = 10
        interval_seconds        = 5
        failure_count_threshold = 60
      }

      env {
        name  = "AOAI_API_BASE"
        value = var.aoai_api_base
      }
      env {
        name  = "FOUNDRY_API_BASE"
        value = var.foundry_api_base
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = var.litellm_client_id
      }
      env {
        name  = "LITELLM_MASTER_KEY"
        value = var.litellm_master_key
      }
    }
  }
}

output "litellm_fqdn" {
  description = "Internal FQDN of the LiteLLM Container App (null until litellm_image is set). APIM /responses service_url."
  value       = one(azurerm_container_app.litellm[*].ingress[0].fqdn)
}

output "environment_id" {
  description = "Container Apps environment resource ID."
  value       = azurerm_container_app_environment.cp.id
}
output "job_name" {
  description = "Config-sync job name (null when worker_image is unset)."
  value       = one(azurerm_container_app_job.config_sync[*].name)
}

output "admin_ui_fqdn" {
  description = "Internal FQDN of the Admin UI Container App (null until admin_ui_image is set). Resolves to the env static IP via the ACA private DNS zone, from inside the VNet only."
  value       = one(azurerm_container_app.admin_ui[*].ingress[0].fqdn)
}
