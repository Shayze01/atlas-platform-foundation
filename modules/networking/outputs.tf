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
