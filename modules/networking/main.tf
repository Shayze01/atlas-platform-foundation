resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "workload" {
  name                 = "snet-workload"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_address_prefix]

  # Private subnet: no implicit Azure "default outbound access". The VM gets
  # explicit outbound connectivity from the Standard public IP on its NIC.
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "workload" {
  name                = "nsg-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_network_security_rule" "allow_ssh_from_admin" {
  name                        = "Allow-SSH-From-Admin"
  description                 = "SSH from the single administrator IPv4 address only."
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.admin_source_ip_cidr
  destination_address_prefix  = var.subnet_address_prefix
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.workload.name
}

resource "azurerm_network_security_rule" "allow_http_from_admin" {
  name                        = "Allow-HTTP-From-Admin"
  description                 = "HTTP to the web container from the single administrator IPv4 address only."
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = var.admin_source_ip_cidr
  destination_address_prefix  = var.subnet_address_prefix
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.workload.name
}

# Azure's built-in rule 65500 already denies inbound Internet traffic. This
# explicit rule documents that intent and shows up clearly in the portal.
resource "azurerm_network_security_rule" "deny_internet_inbound" {
  name                        = "Deny-Internet-Inbound"
  description                 = "Explicitly deny all other inbound traffic from the Internet."
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.workload.name
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  subnet_id                 = azurerm_subnet.workload.id
  network_security_group_id = azurerm_network_security_group.workload.id

  # Ensure rules exist before the NSG is attached and the VM can boot.
  depends_on = [
    azurerm_network_security_rule.allow_ssh_from_admin,
    azurerm_network_security_rule.allow_http_from_admin,
    azurerm_network_security_rule.deny_internet_inbound,
  ]
}
