# ============================================================
# DNS Configuration (云解析 DNS)
# ============================================================

variable "domain_name" {
  description = "已注册的主域名（需已接入阿里云云解析 DNS），如 ohmynet.vip"
  type        = string
  default     = "ohmynet.vip"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]*(\\.[a-zA-Z0-9-]+)+$", var.domain_name))
    error_message = "domain_name 必须是合法的域名格式，如 ohmynet.vip。"
  }
}

# --- public 子网所有 ECS 的 A 记录 ---
# 为 public_devices.instances 中每台 ECS 添加 A 记录：
#   <实例 domain_name>.<var.domain_name> → 该实例公网 IP
# 实例的 domain_name 是子域名前缀（不含主域名），如 "bastion" → bastion.ohmynet.vip；
# 公网子网所有实例均须设置（由 vpc.tf 中 public_devices 的 validation 强制），
# 且都有公网 IP，因此每条记录都能指向对应实例的公网 IP（自动跟随 ECS 重建/IP 变化）。
resource "alicloud_alidns_record" "ecs" {
  for_each = var.public_devices.instances

  domain_name = var.domain_name
  type        = "A"
  rr          = each.value.domain_name
  value       = alicloud_instance.ecs[each.key].public_ip
  ttl         = 600
}

output "dns_records" {
  description = "DNS A records created (instance name -> full domain name)"
  value       = { for k, v in alicloud_alidns_record.ecs : k => "${v.rr}.${v.domain_name}" }
}
