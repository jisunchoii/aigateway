variable "name_suffix" {
  type        = string
  description = "Naming suffix (workload-env-region) for resource names."
}
variable "suffix" {
  type        = string
  description = "Random per-deployment suffix for globally-unique names (the APIM public IP DNS label)."
}
variable "resource_group_name" {
  type        = string
  description = "Resource group to create network resources in."
}
variable "location" {
  type        = string
  description = "Azure region."
}
variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources."
}
variable "vnet_cidr" {
  type        = string
  default     = "10.40.0.0/16"
  description = "Address space for the gateway VNet."
}
variable "apim_subnet_cidr" {
  type        = string
  default     = "10.40.1.0/24"
  description = "CIDR for the APIM injection subnet."
}
variable "pe_subnet_cidr" {
  type        = string
  default     = "10.40.2.0/24"
  description = "CIDR for the private endpoint subnet."
}
variable "enable_jumpbox" {
  type        = bool
  default     = false
  description = "When true, create the Bastion and jumpbox subnets for in-VNet smoke testing."
}
variable "apim_public" {
  type        = bool
  default     = false
  description = "When true, the APIM NSG admits inbound HTTPS from the internet (for APIM External VNet mode). When false (default), only VNet-sourced clients may reach the gateway on 443."
}
variable "bastion_subnet_cidr" {
  type        = string
  default     = "10.40.3.0/26"
  description = "CIDR for AzureBastionSubnet (must be /26 or larger; name is fixed by Azure)."
}
variable "jumpbox_subnet_cidr" {
  type        = string
  default     = "10.40.4.0/24"
  description = "CIDR for the jumpbox VM subnet."
}

variable "aca_subnet_cidr" {
  type        = string
  default     = "10.40.5.0/27"
  description = "CIDR for the Container Apps environment infrastructure subnet (min /27, delegated to Microsoft.App/environments)."
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

# NOTE: Do NOT add a subnet delegation here. Classic Developer/Premium APIM VNet
# injection requires the subnet delegation to be None (per Microsoft docs).
# Subnet delegation is only for the Premium v2 injection model, which we don't use.
resource "azurerm_subnet" "apim" {
  name                 = "snet-apim"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.apim_subnet_cidr]
}

resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.pe_subnet_cidr]
}

resource "azurerm_subnet" "bastion" {
  count                = var.enable_jumpbox ? 1 : 0
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.bastion_subnet_cidr]
}

resource "azurerm_subnet" "jumpbox" {
  count                = var.enable_jumpbox ? 1 : 0
  name                 = "snet-jumpbox"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.jumpbox_subnet_cidr]
}

resource "azurerm_subnet" "aca" {
  name                 = "snet-aca"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.aca_subnet_cidr]

  delegation {
    name = "aca-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_network_security_group" "apim" {
  name                = "nsg-apim-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "in-client-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "in-apim-management"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "in-load-balancer"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }

  # Public exposure (APIM External mode): admit client HTTPS from the internet. Only rendered when
  # apim_public = true; otherwise the gateway stays reachable from VirtualNetwork sources only.
  dynamic "security_rule" {
    for_each = var.apim_public ? [1] : []
    content {
      name                       = "in-internet-https"
      priority                   = 105
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefix      = "Internet"
      destination_address_prefix = "VirtualNetwork"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}

# Required for classic-tier VNet injection on the stv2 platform (internal mode included).
resource "azurerm_public_ip" "apim" {
  name                = "pip-apim-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  # APIM internal VNet injection requires the public IP to carry an FQDN (DNS label).
  # The random suffix keeps the label globally unique across re-creates / parallel stacks.
  domain_name_label = "apim-${var.name_suffix}-${var.suffix}"
  tags              = var.tags

  lifecycle {
    # Azure attaches system-managed ip_tags (e.g. FirstPartyUsage=/Unprivileged) when the
    # APIM internal load balancer claims this IP. ip_tags is immutable, so trying to "remove"
    # it forces a destroy/recreate — which fails because the IP is still bound to the APIM LB.
    # Ignore the platform-managed values so the IP is never needlessly replaced.
    ignore_changes = [ip_tags, zones]
  }
}

locals {
  private_dns_zones = {
    openai            = "privatelink.openai.azure.com"
    keyvault          = "privatelink.vaultcore.azure.net"
    cosmos            = "privatelink.documents.azure.com"
    cognitiveservices = "privatelink.cognitiveservices.azure.com"
    aiservices        = "privatelink.services.ai.azure.com"
  }
}

resource "azurerm_private_dns_zone" "zones" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each              = azurerm_private_dns_zone.zones
  name                  = "link-${each.key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
  tags                  = var.tags
}

output "vnet_id" {
  description = "Resource ID of the gateway VNet."
  value       = azurerm_virtual_network.vnet.id
}
output "apim_subnet_id" {
  description = "Resource ID of the APIM injection subnet."
  value       = azurerm_subnet.apim.id
}
output "pe_subnet_id" {
  description = "Resource ID of the private endpoint subnet."
  value       = azurerm_subnet.pe.id
}
output "apim_public_ip_id" {
  description = "Resource ID of the APIM Standard public IP."
  value       = azurerm_public_ip.apim.id
}
output "dns_zone_ids" {
  description = "Map of private DNS zone keys (openai, keyvault) to their resource IDs."
  value       = { for k, z in azurerm_private_dns_zone.zones : k => z.id }
}
output "bastion_subnet_id" {
  description = "AzureBastionSubnet ID (null when jumpbox disabled)."
  value       = one(azurerm_subnet.bastion[*].id)
}
output "jumpbox_subnet_id" {
  description = "Jumpbox VM subnet ID (null when jumpbox disabled)."
  value       = one(azurerm_subnet.jumpbox[*].id)
}

output "aca_subnet_id" {
  description = "Container Apps environment infrastructure subnet ID."
  value       = azurerm_subnet.aca.id
}
