output "resource_group_name" {
  description = "Name of the primary resource group for this workload."
  value       = azurerm_resource_group.rg.name
}

output "apim_private_ip" {
  description = "APIM internal gateway private IP. Use with smoke-gateway.ps1 --resolve from inside the VNet."
  value       = module.apim.private_ip
}

output "apim_gateway_url" {
  description = "APIM gateway URL (resolves to the private IP from inside the VNet)."
  value       = module.apim.gateway_url
}

output "vscode_base_url" {
  description = "Base URL prefix for VS Code BYOK model URLs."
  value       = module.apim.vscode_base_url
}

output "openai_endpoint" {
  description = "Azure OpenAI account endpoint. Use with smoke-direct-blocked.ps1 from outside the VNet. Null in reuse mode (no dedicated Azure OpenAI account)."
  value       = try(module.openai[0].endpoint, null)
}

# --- Phase 3a: dynamic config (Cosmos + sync worker) ---
# Non-secret references the deploy runbook needs (see README "Phase 3a"). Account/registry
# names, endpoints, and the job name are not secrets, so exposing them is safe.

output "registry_name" {
  description = "Container Registry name. Use with: az acr build --registry $(terraform output -raw registry_name) ..."
  value       = module.registry.name
}

output "registry_login_server" {
  description = "ACR login server. The worker_image var is \"<this>/config-sync:latest\"."
  value       = module.registry.login_server
}

output "config_store_endpoint" {
  description = "Cosmos DB document endpoint. Pass to scripts/seed-cosmos-jumpbox.sh."
  value       = module.config_store.endpoint
}

output "config_store_account_name" {
  description = "Cosmos DB account name (for az cosmosdb / portal Data Explorer)."
  value       = module.config_store.account_name
}

output "config_sync_job_name" {
  description = "Config-sync Container Apps Job name (null until worker_image is set). Use with az containerapp job start."
  value       = module.control_plane.job_name
}

output "admin_ui_fqdn" {
  description = "Internal FQDN of the Admin UI (null until admin_ui_image is set). Browse to https://<this> from inside the VNet (jumpbox)."
  value       = module.control_plane.admin_ui_fqdn
}
