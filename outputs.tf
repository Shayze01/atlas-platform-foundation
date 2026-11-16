output "resource_group_name" {
  description = "Name of the resource group containing every resource in this project."
  value       = local.resource_group_name
}

output "vm_name" {
  description = "Name of the Linux virtual machine."
  value       = module.compute.vm_name
}

output "public_ip_address" {
  description = "Static public IPv4 address of the VM."
  value       = module.compute.public_ip_address
}

output "ssh_command" {
  description = "SSH command to connect to the VM (adjust the private key path if needed)."
  value       = "ssh -i ~/.ssh/atlas_admin ${var.admin_username}@${module.compute.public_ip_address}"
}

output "web_url" {
  description = "URL of the containerised web service (reachable only from admin_source_ip_cidr)."
  value       = "http://${module.compute.public_ip_address}/"
}

output "health_url" {
  description = "Health endpoint URL; should return HTTP 200."
  value       = "http://${module.compute.public_ip_address}/health"
}

output "auto_shutdown_schedule" {
  description = "Daily auto-shutdown (deallocate) time and time zone, or null if disabled."
  value       = module.compute.auto_shutdown_schedule
}

output "app_image" {
  description = "Exact image digest the VM was told to run (also checked in the VM and via /version)."
  value       = var.app_image
}

output "expires_at" {
  description = "Environment expiry (UTC): ExpiresAt tag value and guest app stop time. Not a guarantee that resources are deleted by then."
  value       = var.expires_at
}
