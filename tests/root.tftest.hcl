# Offline tests for the root configuration: variable validation, tags and the
# rendered cloud-init. Uses a mocked provider, so nothing is created in Azure.
# The SSH key below is a throwaway public key generated for tests; its private
# half was deleted immediately and it is not used anywhere.
mock_provider "azurerm" {}

variables {
  owner                = "tester@example.com"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAhnnlI7ScyqxeIK1AysQ0aqybx6fYKZbROGFSh78TQ atlas-test-only"
  admin_source_ip_cidr = "203.0.113.10/32"
}

run "plan_with_valid_inputs" {
  command = plan

  assert {
    condition     = azurerm_resource_group.this.name == "rg-atlas-foundation-dev" && azurerm_resource_group.this.location == "eastus"
    error_message = "Resource group name/location defaults are wrong."
  }

  assert {
    condition = azurerm_resource_group.this.tags == tomap({
      Project     = "atlas-foundation"
      Environment = "dev"
      Owner       = "tester@example.com"
      ManagedBy   = "Terraform"
    })
    error_message = "Resource group must carry the Project, Environment, Owner and ManagedBy tags."
  }

  assert {
    condition     = startswith(local.cloud_init, "#cloud-config")
    error_message = "cloud-init must start with #cloud-config."
  }

  assert {
    condition     = strcontains(local.cloud_init, "docker.io") && strcontains(local.cloud_init, "/opt/atlas/app/run-container.sh")
    error_message = "cloud-init must install Docker and start the web container."
  }

  assert {
    condition     = strcontains(local.cloud_init, "Atlas Platform Foundation") && strcontains(local.cloud_init, "location = /health")
    error_message = "cloud-init must embed the landing page and /health endpoint."
  }

  assert {
    condition     = strcontains(local.cloud_init, "PasswordAuthentication no")
    error_message = "cloud-init must harden sshd against password logins."
  }
}

run "rejects_internet_wide_source" {
  command = plan
  variables {
    admin_source_ip_cidr = "0.0.0.0/0"
  }
  expect_failures = [var.admin_source_ip_cidr]
}

run "rejects_ip_range_wider_than_32" {
  command = plan
  variables {
    admin_source_ip_cidr = "203.0.113.0/24"
  }
  expect_failures = [var.admin_source_ip_cidr]
}

run "rejects_ip_without_prefix" {
  command = plan
  variables {
    admin_source_ip_cidr = "203.0.113.10"
  }
  expect_failures = [var.admin_source_ip_cidr]
}

run "rejects_private_key" {
  command = plan
  variables {
    admin_ssh_public_key = "PRIVATE KEY placeholder - simulates pasting a private key"
  }
  expect_failures = [var.admin_ssh_public_key]
}

run "rejects_reserved_admin_username" {
  command = plan
  variables {
    admin_username = "admin"
  }
  expect_failures = [var.admin_username]
}
