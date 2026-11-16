# Offline tests for the root configuration: variable validation, tags and the
# rendered cloud-init. Uses a mocked provider, so nothing is created in Azure.
# The SSH key below is a throwaway public key generated for tests; its private
# half was deleted immediately and it is not used anywhere.
mock_provider "azurerm" {}

variables {
  owner                = "tester@example.com"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAhnnlI7ScyqxeIK1AysQ0aqybx6fYKZbROGFSh78TQ atlas-test-only"
  admin_source_ip_cidr = "203.0.113.10/32"
  app_image            = "ghcr.io/shayze01/atlas-tickets@sha256:a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  app_variant          = "healthy"
  expires_at           = "2026-11-16T22:35:00Z"
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
      ExpiresAt   = "2026-11-16T22:35:00Z"
      AppVariant  = "healthy"
    })
    error_message = "Common tags must include Project, Environment, Owner, ManagedBy, ExpiresAt and AppVariant."
  }

  assert {
    condition     = startswith(local.cloud_init, "#cloud-config")
    error_message = "cloud-init must start with #cloud-config."
  }

  assert {
    condition     = strcontains(local.cloud_init, "docker.io") && strcontains(local.cloud_init, "ExecStart=/opt/atlas/run-tickets.sh")
    error_message = "cloud-init must install Docker and start the ticket app through the boot-time expiry check."
  }

  assert {
    condition     = strcontains(local.cloud_init, "ATLAS_IMAGE=ghcr.io/shayze01/atlas-tickets@sha256:a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\n")
    error_message = "cloud-init must pin exactly var.app_image."
  }

  assert {
    condition     = strcontains(local.cloud_init, "ATLAS_EXPIRES_AT=2026-11-16T22:35:00Z\n") && strcontains(local.cloud_init, "OnCalendar=2026-11-16 22:35:00 UTC\n")
    error_message = "cloud-init must carry expires_at and fire the expiry timer at that UTC time."
  }

  assert {
    condition     = !strcontains(local.cloud_init, "docker build") && !strcontains(local.cloud_init, "/opt/atlas/app/")
    error_message = "The VM must not build an image or embed the Milestone 2 web page."
  }

  assert {
    condition     = output.app_image == var.app_image && output.expires_at == var.expires_at
    error_message = "app_image and expires_at must be exposed as outputs for the in-VM digest check and reports."
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

run "rejects_image_tag_instead_of_digest" {
  command = plan
  variables {
    app_image = "ghcr.io/shayze01/atlas-tickets:latest"
  }
  expect_failures = [var.app_image]
}

run "rejects_image_from_another_namespace" {
  command = plan
  variables {
    app_image = "ghcr.io/someone-else/atlas-tickets@sha256:a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  }
  expect_failures = [var.app_image]
}

run "rejects_short_digest" {
  command = plan
  variables {
    app_image = "ghcr.io/shayze01/atlas-tickets@sha256:a1a1"
  }
  expect_failures = [var.app_image]
}

run "rejects_unknown_variant" {
  command = plan
  variables {
    app_variant = "broken"
  }
  expect_failures = [var.app_variant]
}

run "rejects_expiry_with_offset" {
  command = plan
  variables {
    expires_at = "2026-11-16T22:35:00+00:00"
  }
  expect_failures = [var.expires_at]
}

run "rejects_impossible_expiry_date" {
  command = plan
  variables {
    expires_at = "2026-02-30T10:00:00Z"
  }
  expect_failures = [var.expires_at]
}
