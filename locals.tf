locals {
  name_suffix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "Terraform"
  }

  # The web app files are embedded into cloud-init so the VM builds exactly
  # the same container image that is tested locally from ./app.
  cloud_init = templatefile("${path.module}/cloud-init/cloud-init.yaml.tftpl", {
    admin_username   = var.admin_username
    dockerfile       = file("${path.module}/app/Dockerfile")
    nginx_conf       = file("${path.module}/app/nginx.conf")
    index_html       = file("${path.module}/app/index.html")
    run_container_sh = file("${path.module}/app/run-container.sh")
  })
}
