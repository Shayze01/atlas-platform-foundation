resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

module "networking" {
  source = "./modules/networking"

  name_suffix           = local.name_suffix
  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  vnet_address_space    = var.vnet_address_space
  subnet_address_prefix = var.subnet_address_prefix
  admin_source_ip_cidr  = var.admin_source_ip_cidr
  tags                  = local.common_tags
}

module "compute" {
  source = "./modules/compute"

  name_suffix          = local.name_suffix
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  subnet_id            = module.networking.subnet_id
  vm_size              = var.vm_size
  admin_username       = var.admin_username
  admin_ssh_public_key = trimspace(var.admin_ssh_public_key)
  custom_data          = local.cloud_init
  tags                 = local.common_tags

  # Make sure the NSG is attached to the subnet before the VM boots and
  # cloud-init starts, so the VM is never reachable without the NSG.
  depends_on = [module.networking]
}
