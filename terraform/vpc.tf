# ============================================================
# VPC Configuration
# ============================================================

variable "vpc_cidr" {
  description = "VPC IPv4 CIDR block (IPv4 地址范围)"
  type        = string
  default     = "172.16.0.0/16"

  validation {
    condition     = tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr 前缀长度必须 ≤ 16（/16 或更大），才能容纳两个 /24 子网。"
  }
}

variable "vswitch_zone" {
  description = "Availability zone for the VSwitch"
  default     = "cn-wulanchabu-a"
}

variable "sg_name" {
  description = "Security group name"
  default     = "tf-sg-default"
}

# --- 公网/内网设备分组配置 ---
# 公网设备：公网子网 IP 地址段 + ECS 实例列表（名称 / 是否有公网 IP / 是否堡垒机）
# 内网设备：内网子网 IP 地址段 + ECS 实例列表（名称）
variable "public_devices" {
  description = "公网设备配置：公网子网 IP 地址段 + ECS 实例列表（host_name / public_ip / is_bastion）"
  type = object({
    cidr = string
    instances = map(object({
      host_name  = optional(string)
      public_ip  = optional(bool, true) # 需求要求公网子网设备均分配公网 IP（见下方 validation）
      is_bastion = optional(bool, false)
    }))
  })

  validation {
    condition     = can(cidrhost(var.public_devices.cidr, 0))
    error_message = "public_devices.cidr 必须是合法 CIDR 地址段。"
  }

  validation {
    condition = (
      length([for k, v in var.public_devices.instances : k if v.is_bastion]) == 1
    )
    error_message = "public_devices.instances 中必须有且仅有一个 is_bastion = true 的实例（堡垒机/NAT 网关）。"
  }

  validation {
    condition = (
      alltrue([for k, v in var.public_devices.instances : !v.is_bastion || v.public_ip])
    )
    error_message = "堡垒机（is_bastion = true）必须设置 public_ip = true。"
  }

  validation {
    condition = (
      alltrue([for k, v in var.public_devices.instances : v.public_ip])
    )
    error_message = "需求要求 public 子网中所有 ECS 都分配公网 IP：public_devices.instances 的每个实例都必须设置 public_ip = true。"
  }
}

variable "internal_devices" {
  description = "内网设备配置：内网子网 IP 地址段 + ECS 实例列表（host_name）"
  type = object({
    cidr = string
    instances = map(object({
      host_name = optional(string)
    }))
  })

  validation {
    condition     = can(cidrhost(var.internal_devices.cidr, 0))
    error_message = "internal_devices.cidr 必须是合法 CIDR 地址段。"
  }
}

# --- 子网地址段跨变量校验（须在 VPC 内且互不重叠） ---
# 网络/广播地址 → 数值（各段 3 位零填充后拼接，HCL 有序比较仅支持数值）
locals {
  vpc_net_num   = tonumber(join("", [for o in split(".", cidrhost(var.vpc_cidr, 0)) : format("%03s", o)]))
  vpc_bcast_num = tonumber(join("", [for o in split(".", cidrhost(var.vpc_cidr, -1)) : format("%03s", o)]))
  pub_net_num   = tonumber(join("", [for o in split(".", cidrhost(var.public_devices.cidr, 0)) : format("%03s", o)]))
  pub_bcast_num = tonumber(join("", [for o in split(".", cidrhost(var.public_devices.cidr, -1)) : format("%03s", o)]))
  int_net_num   = tonumber(join("", [for o in split(".", cidrhost(var.internal_devices.cidr, 0)) : format("%03s", o)]))
  int_bcast_num = tonumber(join("", [for o in split(".", cidrhost(var.internal_devices.cidr, -1)) : format("%03s", o)]))
}

check "subnet_ranges" {
  assert {
    condition     = local.pub_net_num >= local.vpc_net_num && local.pub_bcast_num <= local.vpc_bcast_num
    error_message = "public_devices.cidr（${var.public_devices.cidr}）必须在 vpc_cidr（${var.vpc_cidr}）范围内。"
  }
  assert {
    condition     = local.int_net_num >= local.vpc_net_num && local.int_bcast_num <= local.vpc_bcast_num
    error_message = "internal_devices.cidr（${var.internal_devices.cidr}）必须在 vpc_cidr（${var.vpc_cidr}）范围内。"
  }
  assert {
    condition     = local.pub_bcast_num < local.int_net_num || local.int_bcast_num < local.pub_net_num
    error_message = "public_devices.cidr 与 internal_devices.cidr 不能重叠。"
  }
}

# --- VPC ---
resource "alicloud_vpc" "vpc" {
  vpc_name          = var.resource_group_name
  cidr_block        = var.vpc_cidr
  resource_group_id = alicloud_resource_manager_resource_group.rg.id
}

# --- VSwitch（双子网：公网设备 / 内网设备） ---
# 公网子网（public_devices.cidr，默认 172.16.0.0/24）放置公网设备（含堡垒机）
resource "alicloud_vswitch" "public" {
  vpc_id       = alicloud_vpc.vpc.id
  cidr_block   = var.public_devices.cidr
  zone_id      = var.vswitch_zone
  vswitch_name = "${var.resource_group_name}-vsw-public"
}

# 内网子网（internal_devices.cidr，默认 172.16.1.0/24）放置内网设备
resource "alicloud_vswitch" "internal" {
  vpc_id       = alicloud_vpc.vpc.id
  cidr_block   = var.internal_devices.cidr
  zone_id      = var.vswitch_zone
  vswitch_name = "${var.resource_group_name}-vsw-internal"
}

# --- Security Group ---
resource "alicloud_security_group" "sg" {
  security_group_name = var.sg_name
  description         = "Default security group created by Terraform"
  vpc_id              = alicloud_vpc.vpc.id
  resource_group_id   = alicloud_resource_manager_resource_group.rg.id
}

# --- Security Group Rules ---
resource "alicloud_security_group_rule" "allow_ssh" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "22/22"
  priority          = 1
  security_group_id = alicloud_security_group.sg.id
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_security_group_rule" "allow_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 1
  security_group_id = alicloud_security_group.sg.id
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_security_group_rule" "allow_https" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "443/443"
  priority          = 1
  security_group_id = alicloud_security_group.sg.id
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_security_group_rule" "allow_icmp" {
  type              = "ingress"
  ip_protocol       = "icmp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.sg.id
  cidr_ip           = "0.0.0.0/0"
}

# --- 内网子网独立路由表：将外网流量指向堡垒机 ENI ---
# 阿里云 VPC 虚拟交换机会对非 VPC CIDR 目的 IP 执行 L3 强制路由。
# 公网子网保持默认路由表（公网 IP 设备直连互联网网关，入站/出站均正常）；
# 内网子网挂独立路由表，通过 0.0.0.0/0 → 堡垒机 ENI 将内网设备的外网流量
# 送达堡垒机进行 NAT 转发。
resource "alicloud_route_table" "internal" {
  vpc_id           = alicloud_vpc.vpc.id
  route_table_name = "${var.resource_group_name}-rtb-internal"
  description      = "内网子网路由表：默认路由指向堡垒机 ENI（NAT 网关）"
}

resource "alicloud_route_table_attachment" "internal" {
  route_table_id = alicloud_route_table.internal.id
  vswitch_id     = alicloud_vswitch.internal.id
}

resource "alicloud_route_entry" "nat_gateway" {
  route_table_id        = alicloud_route_table.internal.id
  destination_cidrblock = "0.0.0.0/0"
  nexthop_type          = "NetworkInterface"
  nexthop_id            = local.bastion_eni_id
}

# 堡垒机 ENI ID（用于 NAT 网关路由条目的 nexthop）
locals {
  bastion_eni_id = [
    for k, v in alicloud_instance.ecs : v.network_interface_id
    if local.all_instances[k].is_bastion
  ][0]
}
