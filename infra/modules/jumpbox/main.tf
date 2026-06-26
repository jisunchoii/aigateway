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
  description = "Short random suffix used for the VM computer_name (hostname)."
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
variable "cosmos_endpoint" {
  type        = string
  default     = null
  description = "Cosmos DB document endpoint the seed run-command writes to (https://<account>.documents.azure.com:443/)."
}
variable "seed_role_assignment_id" {
  type        = string
  default     = null
  description = "Cosmos data-plane role assignment ID the seed run-command must wait for (ordering + propagation)."
}
variable "cosmos_pe_id" {
  type        = string
  default     = null
  description = "Cosmos DB private endpoint resource ID (incl. its inline private_dns_zone_group). Referenced by the seed run-command so it waits for the PE NIC AND the privatelink DNS A-record to exist before the VM tries to resolve the Cosmos host."
}
variable "run_seed" {
  type        = bool
  default     = true
  description = "When true (and the jumpbox is enabled), run the Cosmos + pricing seed scripts on the VM via a run-command."
}

locals {
  c      = var.enabled ? 1 : 0
  seed_c = var.enabled && var.run_seed ? 1 : 0
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

resource "azurerm_linux_virtual_machine" "vm" {
  count                 = local.c
  name                  = "vm-jump-${var.name_suffix}"
  computer_name         = "jump-${var.suffix}"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.vm[0].id]
  tags                  = var.tags

  # Password auth is enabled so you can sign in over Bastion without managing SSH keys.
  disable_password_authentication = false

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# One-shot seed job: writes the Cosmos `config`/`pricing` docs from the jumpbox using its
# managed identity. The script embeds the repo seed scripts verbatim and retries to absorb
# data-plane RBAC propagation. Referencing seed_role_assignment_id forces this to run only
# AFTER the Cosmos role assignment exists.
resource "azurerm_virtual_machine_run_command" "seed" {
  count              = local.seed_c
  name               = "seed-cosmos-config"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.vm[0].id

  source {
    # Strip CR so the script has LF endings even if the .tftpl / .sh files are saved as CRLF
    # on Windows (otherwise the Linux shebang becomes "bash\r" and fails with exit 127).
    script = replace(templatefile("${path.module}/seed-runcommand.sh.tftpl", {
      endpoint       = var.cosmos_endpoint
      rbac_id        = coalesce(var.seed_role_assignment_id, "none")
      pe_ready       = coalesce(var.cosmos_pe_id, "none")
      cosmos_script  = file("${path.module}/../../../scripts/seed-cosmos-jumpbox.sh")
      pricing_script = file("${path.module}/../../../scripts/seed-pricing-jumpbox.sh")
    }), "\r", "")
  }
}

output "vm_name" {
  description = "Jumpbox VM name (null when disabled)."
  value       = one(azurerm_linux_virtual_machine.vm[*].name)
}
output "vm_principal_id" {
  description = "Jumpbox VM system-assigned identity principal ID (null when disabled)."
  value       = try(azurerm_linux_virtual_machine.vm[0].identity[0].principal_id, null)
}
output "bastion_name" {
  description = "Bastion host name (null when disabled)."
  value       = one(azurerm_bastion_host.this[*].name)
}
output "seed_run_command_name" {
  description = "Name of the Cosmos seed run-command (null when not run)."
  value       = one(azurerm_virtual_machine_run_command.seed[*].name)
}
