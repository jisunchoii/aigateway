variable "enabled" {
  type        = bool
  default     = false
  description = "Master switch; when false the module creates nothing."
}
variable "name_suffix" {
  type        = string
  description = "Naming suffix (workload-env-region) for resource names."
}
variable "suffix" {
  type        = string
  description = "Short random suffix used for the Windows computer_name (<=15 chars)."
}
variable "resource_group_name" {
  type        = string
  description = "Resource group to create jumpbox resources in."
}
variable "location" {
  type        = string
  description = "Azure region."
}
variable "tags" {
  type        = map(string)
  description = "Tags applied to all jumpbox resources."
}
variable "bastion_subnet_id" {
  type    = string
  default = null
}
variable "jumpbox_subnet_id" {
  type    = string
  default = null
}
variable "admin_username" {
  type        = string
  default     = "azureadmin"
  description = "Local admin username for the jumpbox VM."
}
variable "admin_password" {
  type        = string
  default     = null
  nullable    = true
  sensitive   = true
  description = "Local admin password for the jumpbox VM (provide via tfvars or env; not stored in code)."
}
variable "vm_size" {
  type        = string
  default     = "Standard_B2s_v2"
  description = "VM size for the jumpbox. B2s_v2 is available in koreacentral (B2s hit capacity restrictions)."
}

locals {
  c = var.enabled ? 1 : 0
}

resource "azurerm_public_ip" "bastion" {
  count               = local.c
  name                = "pip-bastion-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags

  lifecycle {
    # Azure attaches system-managed ip_tags when Bastion claims this IP; ip_tags is immutable
    # so a "removal" would force destroy/recreate. Ignore platform-managed values.
    ignore_changes = [ip_tags, zones]
  }
}

resource "azurerm_bastion_host" "this" {
  count               = local.c
  name                = "bas-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                 = "ipcfg"
    subnet_id            = var.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}

resource "azurerm_network_interface" "vm" {
  count               = local.c
  name                = "nic-jump-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipcfg"
    subnet_id                     = var.jumpbox_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "vm" {
  count = local.c
  name  = "vm-jump-${var.name_suffix}"
  # Windows computer_name max 15 chars; derive a short stable name from the random suffix
  # ("jump-" + 6-char suffix = 11) since the full resource name (21 chars) exceeds the limit.
  computer_name         = "jump-${var.suffix}"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.vm[0].id]
  tags                  = var.tags

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
}

output "vm_name" {
  description = "Jumpbox VM name (null when disabled)."
  value       = one(azurerm_windows_virtual_machine.vm[*].name)
}
output "vm_principal_id" {
  description = "Jumpbox VM system-assigned identity principal ID (null when disabled)."
  value       = try(azurerm_windows_virtual_machine.vm[0].identity[0].principal_id, null)
}
output "bastion_name" {
  description = "Bastion host name (null when disabled)."
  value       = one(azurerm_bastion_host.this[*].name)
}
