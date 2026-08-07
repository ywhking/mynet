# ============================================================
# ECS Configuration
# ============================================================

variable "ecs_ssh_public_key" {
  description = "SSH public key content (optional; if empty, auto-generates locally via generate_key.sh)"
  type        = string
  default     = ""
}

variable "ecs_instance_type" {
  description = "ECS instance type"
  default     = "ecs.t6-c1m2.large"
}

variable "ecs_instances" {
  description = "ECS instances configuration. Map key = ECS instance name. Exactly one instance must have public_ip = true."
  type = map(object({
    host_name = optional(string)
    public_ip = optional(bool, false)
  }))

  validation {
    condition = (
      length([for k, v in var.ecs_instances : k if v.public_ip]) == 1
    )
    error_message = "Exactly one ECS instance must have public_ip = true."
  }
}

# --- Ubuntu 24.04 镜像 ---
data "alicloud_images" "ubuntu" {
  name_regex  = "^ubuntu_24_04_x64_20G_alibase_"
  most_recent = true
  owners      = "system"
}

# --- 本地生成/读取 SSH 密钥对（每个 ECS 独立一个） ---
data "external" "ssh_key" {
  for_each = var.ecs_instances
  program  = ["bash", "${path.module}/scripts/generate_key.sh"]
  query = {
    key_name   = "KEY-${each.key}"
    public_key = var.ecs_ssh_public_key
  }
}

# --- SSH 密钥对（每个 ECS 独立一个，上传公钥到阿里云） ---
resource "alicloud_key_pair" "per_ecs" {
  for_each          = var.ecs_instances
  key_pair_name     = "KEY-${each.key}"
  public_key        = data.external.ssh_key[each.key].result.public_key
  resource_group_id = alicloud_resource_manager_resource_group.rg.id
}

# --- ECS 实例（动态数量） ---
resource "alicloud_instance" "ecs" {
  for_each = var.ecs_instances

  instance_name              = each.key
  host_name                  = try(each.value.host_name, each.key)
  instance_type              = var.ecs_instance_type
  image_id                   = data.alicloud_images.ubuntu.images[0].id
  vswitch_id                 = alicloud_vswitch.vswitch.id
  security_groups            = [alicloud_security_group.sg.id]
  key_name                   = alicloud_key_pair.per_ecs[each.key].key_pair_name
  internet_max_bandwidth_out = each.value.public_ip ? 10 : 0
  internet_charge_type       = each.value.public_ip ? "PayByTraffic" : null
  system_disk_category       = "cloud_efficiency"
  system_disk_size           = 40
  resource_group_id          = alicloud_resource_manager_resource_group.rg.id
}

# --- 输出 ---
output "ecs_key_pair_names" {
  description = "ECS key pair names (keyed by instance name)"
  value       = { for k, v in alicloud_key_pair.per_ecs : k => v.key_pair_name }
}

output "ecs_public_ips" {
  description = "Public IPs of internet-facing ECS instances"
  value       = { for k, v in alicloud_instance.ecs : k => v.public_ip if var.ecs_instances[k].public_ip }
}

output "ecs_private_ips" {
  description = "Private IPs of all ECS instances (keyed by instance name)"
  value       = { for k, v in alicloud_instance.ecs : k => v.private_ip }
}

output "bastion_name" {
  description = "Bastion (NAT gateway) ECS instance name"
  value       = [for k, v in var.ecs_instances : k if v.public_ip][0]
}

output "bastion_public_ip" {
  description = "Bastion (NAT gateway) ECS public IP"
  value       = [for k, v in alicloud_instance.ecs : v.public_ip if var.ecs_instances[k].public_ip][0]
}

output "bastion_private_ip" {
  description = "Bastion (NAT gateway) ECS private IP"
  value       = [for k, v in alicloud_instance.ecs : v.private_ip if var.ecs_instances[k].public_ip][0]
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = var.vpc_cidr
}
