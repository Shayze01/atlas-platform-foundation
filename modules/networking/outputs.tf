output "vnet_id" {
  description = "ID of the virtual network."
  value       = azurerm_virtual_network.this.id
}

output "subnet_id" {
  description = "ID of the workload subnet (NSG already associated)."
  value       = azurerm_subnet_network_security_group_association.workload.subnet_id
}

output "nsg_id" {
  description = "ID of the network security group."
  value       = azurerm_network_security_group.workload.id
}

output "test_rule_names" {
  description = "Names of temporary test rules (empty unless test_source_ip_cidrs is set)."
  value       = azurerm_network_security_rule.allow_test_sources[*].name
}

output "test_rule_source_prefixes" {
  description = "Sources allowed by the temporary test rule (empty when it does not exist)."
  value       = flatten(azurerm_network_security_rule.allow_test_sources[*].source_address_prefixes)
}
