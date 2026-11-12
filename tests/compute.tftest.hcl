# Offline unit tests for the compute module (mocked provider, no credentials).
# The SSH key below is a throwaway public key generated for tests; its private
# half was deleted immediately and it is not used anywhere.
mock_provider "azurerm" {}

variables {
  name_suffix          = "atlas-foundation-test"
  resource_group_name  = "rg-atlas-foundation-test"
  location             = "eastus"
  subnet_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-atlas-foundation-test/providers/Microsoft.Network/virtualNetworks/vnet-atlas-foundation-test/subnets/snet-workload"
  vm_size              = "Standard_B2ats_v2"
  admin_username       = "atlasadmin"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAhnnlI7ScyqxeIK1AysQ0aqybx6fYKZbROGFSh78TQ atlas-test-only"
  custom_data          = "#cloud-config\n"
  tags = {
    Project     = "atlas-foundation"
    Environment = "test"
    Owner       = "tester"
    ManagedBy   = "Terraform"
  }
}

run "vm_uses_ssh_keys_only" {
  command = plan

  module {
    source = "./modules/compute"
  }

  assert {
    condition     = azurerm_linux_virtual_machine.this.disable_password_authentication == true
    error_message = "Password authentication must be disabled."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.this.admin_password == null
    error_message = "No admin password may be set."
  }

  assert {
    condition     = one(azurerm_linux_virtual_machine.this.admin_ssh_key).username == "atlasadmin"
    error_message = "The SSH key must belong to the admin user."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.this.source_image_reference[0].publisher == "Canonical" && azurerm_linux_virtual_machine.this.source_image_reference[0].offer == "ubuntu-24_04-lts"
    error_message = "VM must use the Ubuntu 24.04 LTS image by default."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.this.custom_data == base64encode("#cloud-config\n")
    error_message = "cloud-init must be passed base64-encoded as custom_data."
  }

  assert {
    condition     = azurerm_public_ip.vm.sku == "Standard" && azurerm_public_ip.vm.allocation_method == "Static"
    error_message = "Public IP must be Standard SKU with static allocation."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.this.tags["Environment"] == "test" && azurerm_public_ip.vm.tags["Owner"] == "tester" && azurerm_network_interface.vm.tags["ManagedBy"] == "Terraform"
    error_message = "Compute resources must carry the common tags."
  }
}

# Mocked apply: no real resources are created. Fake but well-formed Azure IDs
# are supplied so the NIC-to-public-IP reference can be compared.
run "public_ip_attached_to_nic_for_explicit_outbound" {
  command = apply

  module {
    source = "./modules/compute"
  }

  override_resource {
    target = azurerm_public_ip.vm
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-atlas-foundation-test/providers/Microsoft.Network/publicIPAddresses/pip-atlas-foundation-test"
    }
  }

  override_resource {
    target = azurerm_network_interface.vm
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-atlas-foundation-test/providers/Microsoft.Network/networkInterfaces/nic-atlas-foundation-test"
    }
  }

  assert {
    condition     = azurerm_network_interface.vm.ip_configuration[0].public_ip_address_id == azurerm_public_ip.vm.id
    error_message = "The Standard public IP must be attached to the NIC's primary IP configuration."
  }

  assert {
    condition     = azurerm_network_interface.vm.ip_configuration[0].subnet_id == var.subnet_id
    error_message = "The NIC must be connected to the workload subnet."
  }

  assert {
    condition     = output.nic_public_ip_address_id == azurerm_public_ip.vm.id
    error_message = "Module output must expose the NIC's public IP ID."
  }
}
