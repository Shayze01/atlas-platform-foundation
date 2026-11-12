variable "name_suffix" {
  description = "Suffix appended to resource names, e.g. atlas-foundation-dev."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group in which to create the compute resources."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "subnet_id" {
  description = "ID of the subnet the VM network interface connects to."
  type        = string
}

variable "vm_size" {
  description = "Azure VM size."
  type        = string
}

variable "admin_username" {
  description = "Linux administrator username."
  type        = string
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key for the administrator."
  type        = string
}

variable "custom_data" {
  description = "Plain-text cloud-init configuration (base64-encoded by this module)."
  type        = string
}

variable "os_disk_storage_account_type" {
  description = "Managed disk type for the OS disk. Standard_LRS (HDD) is the cheapest."
  type        = string
  default     = "Standard_LRS"
}

variable "image" {
  description = "Marketplace image for the VM. Defaults to Ubuntu Server 24.04 LTS (Gen2)."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
}
