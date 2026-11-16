locals {
  name_suffix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "Terraform"
    # Expiry-tag carrier value read by the hourly sweep (see scripts/ci/expiry_map.py).
    ExpiresAt  = var.expires_at
    AppVariant = var.app_variant
  }

  # The VM pulls the exact image digest that was planned and approved; nothing is
  # built on the VM. The expiry timer stops the app and deletes ticket data at
  # expires_at (guest app stop); it does not delete Azure resources.
  cloud_init = templatefile("${path.module}/cloud-init/cloud-init.yaml.tftpl", {
    admin_username    = var.admin_username
    app_image         = var.app_image
    expires_at        = var.expires_at
    expiry_calendar   = replace(replace(var.expires_at, "T", " "), "Z", " UTC")
    environment_label = "azure-${var.environment}"
    run_tickets_sh    = file("${path.module}/cloud-init/files/run-tickets.sh")
    atlas_expire_sh   = file("${path.module}/cloud-init/files/atlas-expire.sh")
  })
}
