resource "azurerm_public_ip" "vm" {
  name                = "pip-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  allocation_method   = "Static"
  tags                = var.tags
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                  = "vm-${var.name_suffix}"
  computer_name         = "atlas-web-01"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  network_interface_ids = [azurerm_network_interface.vm.id]

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  # Changing custom_data forces the VM to be replaced (cloud-init runs on first boot only).
  custom_data = base64encode(var.custom_data)

  os_disk {
    name                 = "osdisk-${var.name_suffix}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
  }

  source_image_reference {
    publisher = var.image.publisher
    offer     = var.image.offer
    sku       = var.image.sku
    version   = var.image.version
  }

  # Managed boot diagnostics: enables the serial log and serial console for
  # troubleshooting boot and cloud-init problems without SSH.
  boot_diagnostics {}

  tags = var.tags
}
