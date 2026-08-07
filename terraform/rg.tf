# ============================================================
# Resource Group
# ============================================================

variable "resource_group_name" {
  description = "Resource group name (资源组名称)"
  type        = string
}

resource "alicloud_resource_manager_resource_group" "rg" {
  resource_group_name = var.resource_group_name
  display_name        = var.resource_group_name
}
