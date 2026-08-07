# ============================================================
# Provider Configuration
# ============================================================

variable "alicloud_region" {
  description = "Alibaba Cloud region (地域)"
  type        = string
}

provider "alicloud" {
  region = var.alicloud_region
}
