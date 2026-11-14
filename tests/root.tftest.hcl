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
    condition     = azurerm_resource_group.this[0].name == "rg-atlas-foundation-dev" && azurerm_resource_group.this[0].location == "eastus"
    error_message = "Resource group name/location defaults are wrong."
  }

  assert {
    condition = azurerm_resource_group.this[0].tags == tomap({
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

run "no_temporary_test_rule_by_default" {
  command = plan

  assert {
    condition     = length(module.networking.test_rule_names) == 0
    error_message = "The temporary test rule must not exist when test_source_ip_cidrs is empty."
  }
}

run "temporary_test_rule_only_allows_listed_32s" {
  command = plan
  variables {
    test_source_ip_cidrs = ["198.51.100.4/32", "198.51.100.8/32"]
  }

  assert {
    condition     = length(module.networking.test_rule_names) == 1
    error_message = "Expected exactly one temporary test rule."
  }

  assert {
    condition     = toset(module.networking.test_rule_source_prefixes) == toset(["198.51.100.4/32", "198.51.100.8/32"])
    error_message = "The temporary rule must allow only the listed /32 sources."
  }
}

run "rejects_test_source_wider_than_32" {
  command = plan
  variables {
    test_source_ip_cidrs = ["198.51.100.0/24"]
  }
  expect_failures = [var.test_source_ip_cidrs]
}

run "rejects_invalid_auto_shutdown_time" {
  command = plan
  variables {
    auto_shutdown_time = "2:00"
  }
  expect_failures = [var.auto_shutdown_time]
}

run "creates_resource_group_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_resource_group.this) == 1 && length(data.azurerm_resource_group.existing) == 0
    error_message = "Milestone 1 default must create the resource group and not look up an existing one."
  }
}

run "uses_existing_resource_group_when_not_creating" {
  command = plan

  variables {
    create_resource_group = false
  }

  override_data {
    target = data.azurerm_resource_group.existing[0]
    values = {
      name     = "rg-atlas-foundation-dev"
      location = "eastus"
    }
  }

  assert {
    condition     = length(azurerm_resource_group.this) == 0
    error_message = "With create_resource_group = false Terraform must not manage (or destroy) the resource group."
  }

  assert {
    condition     = output.resource_group_name == "rg-atlas-foundation-dev" && output.vm_name == "vm-atlas-foundation-dev"
    error_message = "Workload resources must be placed in the existing bootstrap resource group."
  }
}
