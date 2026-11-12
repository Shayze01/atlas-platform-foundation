terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
  }

  # Milestone 1 intentionally uses local state (terraform.tfstate in this folder).
  # See README "Terraform state" for the limitations and the planned remote backend.
}

provider "azurerm" {
  features {}

  # Do not try to register resource providers subscription-wide. The deploying
  # identity may be scoped to one resource group; Microsoft.Compute and
  # Microsoft.Network must already be registered (they are on most subscriptions).
  resource_provider_registrations = "none"
  # The subscription is taken from the ARM_SUBSCRIPTION_ID environment variable
  # (see README) so that no subscription ID is committed to Git.
}
