# ============================================================
# Provider Configuration
# ============================================================

terraform {
  # Pin the providers explicitly. Without this, `terraform init` resolves the
  # NEWEST published version: the portal copies only `*.tf` and `scripts/` into
  # each tenant's working directory (never `.terraform.lock.hcl`), so every
  # tenant resolved independently and an upstream release could change
  # behaviour between two tenants — or break the module outright.
  # Versions match terraform/.terraform.lock.hcl.
  required_providers {
    alicloud = {
      source  = "hashicorp/alicloud"
      version = "= 1.285.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "= 2.4.0"
    }
  }
}

variable "alicloud_region" {
  description = "Alibaba Cloud region (地域)"
  type        = string
}

provider "alicloud" {
  region = var.alicloud_region
}
