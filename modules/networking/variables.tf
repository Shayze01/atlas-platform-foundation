variable "name_suffix" {
  description = "Suffix appended to resource names, e.g. atlas-foundation-dev."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group in which to create the networking resources."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the virtual network."
  type        = string
}

variable "subnet_address_prefix" {
  description = "Address prefix for the workload subnet."
  type        = string
}

variable "admin_source_ip_cidr" {
  description = "Single administrator IPv4 address (/32) allowed to reach SSH and HTTP."
  type        = string
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
}
