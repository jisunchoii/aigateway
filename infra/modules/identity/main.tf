variable "name_suffix" {
  type        = string
  description = "Naming suffix (workload-env-region) shared across all resources in this deployment."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group in which identities are created."
}

variable "location" {
  type        = string
  description = "Azure region for the managed identities."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources in this module."
}

resource "azurerm_user_assigned_identity" "control_plane_read" {
  name                = "id-cp-read-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "control_plane_write" {
  name                = "id-cp-write-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

output "cp_read_principal_id" {
  description = "Object ID of the control-plane READ managed identity (for RBAC assignments)."
  value       = azurerm_user_assigned_identity.control_plane_read.principal_id
}

output "cp_read_client_id" {
  description = "Client ID of the control-plane READ managed identity (for SDK credential configuration)."
  value       = azurerm_user_assigned_identity.control_plane_read.client_id
}

output "cp_read_id" {
  description = "Resource ID of the control-plane READ managed identity (for attaching to compute resources)."
  value       = azurerm_user_assigned_identity.control_plane_read.id
}

output "cp_write_principal_id" {
  description = "Object ID of the control-plane WRITE managed identity (for RBAC assignments)."
  value       = azurerm_user_assigned_identity.control_plane_write.principal_id
}

output "cp_write_client_id" {
  description = "Client ID of the control-plane WRITE managed identity (for SDK credential configuration)."
  value       = azurerm_user_assigned_identity.control_plane_write.client_id
}

output "cp_write_id" {
  description = "Resource ID of the control-plane WRITE managed identity (for attaching to compute resources)."
  value       = azurerm_user_assigned_identity.control_plane_write.id
}

resource "azurerm_user_assigned_identity" "config_sync_worker" {
  name                = "id-config-sync-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

output "worker_principal_id" {
  description = "Object ID of the config-sync worker identity (for Cosmos data-plane + APIM/ACR RBAC)."
  value       = azurerm_user_assigned_identity.config_sync_worker.principal_id
}

output "worker_client_id" {
  description = "Client ID of the config-sync worker identity (AZURE_CLIENT_ID for DefaultAzureCredential)."
  value       = azurerm_user_assigned_identity.config_sync_worker.client_id
}

output "worker_id" {
  description = "Resource ID of the config-sync worker identity (to attach to the Container Apps Job)."
  value       = azurerm_user_assigned_identity.config_sync_worker.id
}
