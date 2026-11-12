# Offline unit tests for the networking module. A mocked azurerm provider is
# used, so no Azure credentials are needed and nothing is created.
mock_provider "azurerm" {}

variables {
  name_suffix           = "atlas-foundation-test"
  resource_group_name   = "rg-atlas-foundation-test"
  location              = "eastus"
  vnet_address_space    = "10.20.0.0/16"
  subnet_address_prefix = "10.20.1.0/24"
  admin_source_ip_cidr  = "203.0.113.10/32"
  tags = {
    Project     = "atlas-foundation"
    Environment = "test"
    Owner       = "tester"
    ManagedBy   = "Terraform"
  }
}

run "nsg_allows_only_admin_ip_on_ssh_and_http" {
  command = plan

  module {
    source = "./modules/networking"
  }

  assert {
    condition     = azurerm_network_security_rule.allow_ssh_from_admin.source_address_prefix == "203.0.113.10/32"
    error_message = "SSH rule must only allow the administrator /32 address."
  }

  assert {
    condition     = azurerm_network_security_rule.allow_ssh_from_admin.destination_port_range == "22" && azurerm_network_security_rule.allow_ssh_from_admin.access == "Allow" && azurerm_network_security_rule.allow_ssh_from_admin.protocol == "Tcp"
    error_message = "SSH rule must allow TCP 22."
  }

  assert {
    condition     = azurerm_network_security_rule.allow_http_from_admin.source_address_prefix == "203.0.113.10/32"
    error_message = "HTTP rule must only allow the administrator /32 address."
  }

  assert {
    condition     = azurerm_network_security_rule.allow_http_from_admin.destination_port_range == "80" && azurerm_network_security_rule.allow_http_from_admin.access == "Allow" && azurerm_network_security_rule.allow_http_from_admin.protocol == "Tcp"
    error_message = "HTTP rule must allow TCP 80."
  }

  assert {
    condition = alltrue([
      for r in [azurerm_network_security_rule.allow_ssh_from_admin, azurerm_network_security_rule.allow_http_from_admin] :
      !contains(["*", "0.0.0.0/0", "Internet", "Any"], r.source_address_prefix)
    ])
    error_message = "No allow rule may use an internet-wide source."
  }

  assert {
    condition     = azurerm_network_security_rule.deny_internet_inbound.access == "Deny" && azurerm_network_security_rule.deny_internet_inbound.source_address_prefix == "Internet"
    error_message = "An explicit deny rule for other Internet inbound traffic must exist."
  }

  assert {
    condition     = azurerm_subnet.workload.address_prefixes == tolist(["10.20.1.0/24"])
    error_message = "Subnet must use the configured address prefix."
  }

  assert {
    condition     = azurerm_subnet.workload.default_outbound_access_enabled == false
    error_message = "Subnet must not rely on implicit default outbound access."
  }

  assert {
    condition     = azurerm_network_security_group.workload.tags["Owner"] == "tester" && azurerm_virtual_network.this.tags["Project"] == "atlas-foundation"
    error_message = "Networking resources must carry the common tags."
  }
}
