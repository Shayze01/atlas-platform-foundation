output "vm_id" {
  description = "ID of the Linux virtual machine."
  value       = azurerm_linux_virtual_machine.this.id
}

output "vm_name" {
  description = "Name of the Linux virtual machine."
  value       = azurerm_linux_virtual_machine.this.name
}

output "public_ip_address" {
  description = "Static public IPv4 address."
  value       = azurerm_public_ip.vm.ip_address
}

output "private_ip_address" {
  description = "Private IPv4 address of the VM in the subnet."
  value       = azurerm_network_interface.vm.private_ip_address
}

output "nic_public_ip_address_id" {
  description = "ID of the public IP attached to the NIC's primary IP configuration (explicit outbound path)."
  value       = azurerm_network_interface.vm.ip_configuration[0].public_ip_address_id
}

output "auto_shutdown_schedule" {
  description = "Auto-shutdown time and time zone (null when disabled)."
  value = var.auto_shutdown_enabled ? {
    time     = azurerm_dev_test_global_vm_shutdown_schedule.this[0].daily_recurrence_time
    timezone = azurerm_dev_test_global_vm_shutdown_schedule.this[0].timezone
  } : null
}
