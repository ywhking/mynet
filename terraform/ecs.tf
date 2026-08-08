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

# --- 合并公网/内网设备为统一结构（供 for_each / 输出使用） ---
locals {
  all_instances = merge(
    { for k, v in var.public_devices.instances : k => {
      host_name  = try(v.host_name, k)
      public_ip  = try(v.public_ip, true)
      is_bastion = try(v.is_bastion, false)
      group      = "public"
    } },
    { for k, v in var.internal_devices.instances : k => {
      host_name  = try(v.host_name, k)
      public_ip  = false
      is_bastion = false
      group      = "internal"
    } },
  )
}

# --- Ubuntu 24.04 镜像 ---
data "alicloud_images" "ubuntu" {
  name_regex  = "^ubuntu_24_04_x64_20G_alibase_"
  most_recent = true
  owners      = "system"
}

# --- 本地生成/读取 SSH 密钥对（每个 ECS 独立一个） ---
data "external" "ssh_key" {
  for_each = local.all_instances
  program  = ["bash", "${path.module}/scripts/generate_key.sh"]
  query = {
    key_name   = "KEY-${each.key}"
    public_key = var.ecs_ssh_public_key
  }
}

# --- SSH 密钥对（每个 ECS 独立一个，上传公钥到阿里云） ---
resource "alicloud_key_pair" "per_ecs" {
  for_each          = local.all_instances
  key_pair_name     = "KEY-${each.key}"
  public_key        = data.external.ssh_key[each.key].result.public_key
  resource_group_id = alicloud_resource_manager_resource_group.rg.id
}

# --- ECS 实例（动态数量） ---
resource "alicloud_instance" "ecs" {
  for_each = local.all_instances

  instance_name              = each.key
  host_name                  = each.value.host_name
  instance_type              = var.ecs_instance_type
  image_id                   = data.alicloud_images.ubuntu.images[0].id
  vswitch_id                 = each.value.group == "public" ? alicloud_vswitch.public.id : alicloud_vswitch.internal.id
  security_groups            = [alicloud_security_group.sg.id]
  key_name                   = alicloud_key_pair.per_ecs[each.key].key_pair_name
  internet_max_bandwidth_out = each.value.public_ip ? 10 : 0
  internet_charge_type       = each.value.public_ip ? "PayByTraffic" : null
  # 堡垒机（NAT 网关）需关闭源/目的检查才能转发内网设备的流量——provider 原生支持
  # （内部调用 ModifyNetworkInterfaceAttribute），无需外部 aliyun CLI。
  # 注意：source_dest_check 是 ForceNew 属性。非堡垒机实例不设置该参数（保持云上默认值），
  # 否则 plan 会显示强制重建实例。
  source_dest_check    = each.value.is_bastion ? false : null
  system_disk_category = "cloud_efficiency"
  system_disk_size     = 40
  resource_group_id    = alicloud_resource_manager_resource_group.rg.id
}

# --- 输出 ---
output "ecs_key_pair_names" {
  description = "ECS key pair names (keyed by instance name)"
  value       = { for k, v in alicloud_key_pair.per_ecs : k => v.key_pair_name }
}

output "ecs_public_ips" {
  description = "Public IPs of instances with public_ip = true (keyed by instance name)"
  value       = { for k, v in alicloud_instance.ecs : k => v.public_ip if local.all_instances[k].public_ip }
}

output "ecs_private_ips" {
  description = "Private IPs of all ECS instances (keyed by instance name)"
  value       = { for k, v in alicloud_instance.ecs : k => v.private_ip }
}

output "bastion_name" {
  description = "Bastion (NAT gateway) ECS instance name (is_bastion = true)"
  value       = [for k, v in local.all_instances : k if v.is_bastion][0]
}

output "bastion_public_ip" {
  description = "Bastion (NAT gateway) ECS public IP"
  value       = [for k, v in alicloud_instance.ecs : v.public_ip if local.all_instances[k].is_bastion][0]
}

output "bastion_private_ip" {
  description = "Bastion (NAT gateway) ECS private IP"
  value       = [for k, v in alicloud_instance.ecs : v.private_ip if local.all_instances[k].is_bastion][0]
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = var.vpc_cidr
}

output "vswitch_public_cidr" {
  description = "Public subnet (bastion) VSwitch CIDR block"
  value       = alicloud_vswitch.public.cidr_block
}

output "vswitch_internal_cidr" {
  description = "Internal subnet VSwitch CIDR block"
  value       = alicloud_vswitch.internal.cidr_block
}
