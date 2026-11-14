# Milestone 1 (local state) creates the resource group. The Milestone 2 deployment
# engine sets create_resource_group = false: the group and its role assignments are
# created once by bootstrap/bootstrap.sh and survive routine terraform destroy.
resource "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 1 : 0

  name     = "rg-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1

  name = "rg-${local.name_suffix}"
}

moved {
  from = azurerm_resource_group.this
  to   = azurerm_resource_group.this[0]
}

locals {
  resource_group_name     = var.create_resource_group ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.existing[0].name
  resource_group_location = var.create_resource_group ? azurerm_resource_group.this[0].location : data.azurerm_resource_group.existing[0].location
}

module "networking" {
  source = "./modules/networking"

  name_suffix           = local.name_suffix
  resource_group_name   = local.resource_group_name
  location              = local.resource_group_location
  vnet_address_space    = var.vnet_address_space
  subnet_address_prefix = var.subnet_address_prefix
  admin_source_ip_cidr  = var.admin_source_ip_cidr
  test_source_ip_cidrs  = var.test_source_ip_cidrs
  tags                  = local.common_tags
}

module "compute" {
  source = "./modules/compute"

  name_suffix          = local.name_suffix
  resource_group_name  = local.resource_group_name
  location             = local.resource_group_location
  subnet_id            = module.networking.subnet_id
  vm_size              = var.vm_size
  admin_username       = var.admin_username
  admin_ssh_public_key = trimspace(var.admin_ssh_public_key)
  custom_data          = local.cloud_init

  auto_shutdown_enabled  = var.auto_shutdown_enabled
  auto_shutdown_time     = var.auto_shutdown_time
  auto_shutdown_timezone = var.auto_shutdown_timezone
  tags                   = local.common_tags

  # Make sure the NSG is attached to the subnet before the VM boots and
  # cloud-init starts, so the VM is never reachable without the NSG.
  depends_on = [module.networking]
}
