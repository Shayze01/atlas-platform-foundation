variable "project_name" {
  description = "Short, lowercase project name used in resource names and the Project tag."
  type        = string
  default     = "atlas-foundation"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.project_name))
    error_message = "project_name must be 3-24 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Environment name used in resource names and the Environment tag."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, prod."
  }
}

variable "owner" {
  description = "Person or team responsible for these resources (Owner tag), e.g. an email address or name."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "location" {
  description = "Azure region for all resources, e.g. eastus. Check VM size availability in the region first."
  type        = string
  default     = "eastus"
}

variable "vm_size" {
  description = "Azure VM size. The default is a low-cost burstable size; change it if unavailable in your region."
  type        = string
  default     = "Standard_B2ats_v2"
}

variable "admin_username" {
  description = "Linux administrator username for SSH."
  type        = string
  default     = "atlasadmin"

  validation {
    condition = (
      can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_username)) &&
      !contains(["admin", "administrator", "root", "user", "guest", "test", "ubuntu"], var.admin_username)
    )
    error_message = "admin_username must be a valid lowercase Linux username and must not be a reserved name such as admin, root or ubuntu."
  }
}

variable "admin_ssh_public_key" {
  description = "Contents of your SSH PUBLIC key (e.g. the text of ~/.ssh/atlas_admin.pub). Never supply a private key."
  type        = string

  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519) [A-Za-z0-9+/=]+( .*)?$", trimspace(var.admin_ssh_public_key)))
    error_message = "admin_ssh_public_key must be an OpenSSH public key starting with 'ssh-rsa' or 'ssh-ed25519'."
  }

  validation {
    condition     = !strcontains(var.admin_ssh_public_key, "PRIVATE KEY")
    error_message = "This looks like a PRIVATE key. Supply the .pub public key only."
  }
}

variable "admin_source_ip_cidr" {
  description = "Your public IPv4 address as a single-host CIDR, e.g. 203.0.113.10/32. Only this address may reach SSH (22) and HTTP (80)."
  type        = string

  validation {
    condition = (
      can(regex("^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])/32$", var.admin_source_ip_cidr)) &&
      var.admin_source_ip_cidr != "0.0.0.0/32"
    )
    error_message = "admin_source_ip_cidr must be a single IPv4 address with a /32 suffix (e.g. 203.0.113.10/32). Ranges such as 0.0.0.0/0 are not allowed."
  }
}

variable "test_source_ip_cidrs" {
  description = "Optional, temporary extra single-host IPv4 sources (/32) allowed to reach SSH (22) and HTTP (80) for deployment testing. Leave empty (the default) for normal use and remove entries as soon as testing ends."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.test_source_ip_cidrs :
      can(regex("^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])/32$", cidr)) && cidr != "0.0.0.0/32"
    ]) && length(var.test_source_ip_cidrs) <= 4
    error_message = "test_source_ip_cidrs may hold at most 4 entries, each a single IPv4 address with a /32 suffix."
  }
}

variable "auto_shutdown_enabled" {
  description = "Daily auto-shutdown (stop + deallocate) of the VM as a safety net against forgotten cleanup. Public IP and disk still bill while deallocated."
  type        = bool
  default     = true
}

variable "auto_shutdown_time" {
  description = "Daily auto-shutdown time as HHMM (24-hour) in auto_shutdown_timezone, e.g. \"0200\"."
  type        = string
  default     = "0200"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "auto_shutdown_time must be HHMM in 24-hour format, e.g. \"0200\"."
  }
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone ID for auto-shutdown. \"GMT Standard Time\" is UK local time (GMT/BST)."
  type        = string
  default     = "GMT Standard Time"
}

variable "vnet_address_space" {
  description = "Address space for the virtual network."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vnet_address_space))
    error_message = "vnet_address_space must be a valid IPv4 CIDR block."
  }
}

variable "subnet_address_prefix" {
  description = "Address prefix for the workload subnet. Must sit inside vnet_address_space."
  type        = string
  default     = "10.20.1.0/24"

  validation {
    condition     = can(cidrnetmask(var.subnet_address_prefix))
    error_message = "subnet_address_prefix must be a valid IPv4 CIDR block."
  }
}
