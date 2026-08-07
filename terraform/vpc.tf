# ============================================================
# VPC Configuration
# ============================================================

variable "vpc_cidr" {
  description = "VPC IPv4 CIDR block (IPv4 地址范围)"
  type        = string
  default     = "172.16.0.0/16"
}

variable "vswitch_zone" {
  description = "Availability zone for the VSwitch"
  default     = "cn-wulanchabu-a"
}

variable "sg_name" {
  description = "Security group name"
  default     = "tf-sg-default"
}

# --- VPC ---
resource "alicloud_vpc" "vpc" {
  vpc_name          = var.resource_group_name
  cidr_block        = var.vpc_cidr
  resource_group_id = alicloud_resource_manager_resource_group.rg.id
}

# --- VSwitch ---
resource "alicloud_vswitch" "vswitch" {
  vpc_id       = alicloud_vpc.vpc.id
  cidr_block   = cidrsubnet(var.vpc_cidr, 8, 1)
  zone_id      = var.vswitch_zone
  vswitch_name = "${var.resource_group_name}-vsw"
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

# --- VPC 路由条目：将外网流量指向堡垒机 ENI ---
# 阿里云 VPC 虚拟交换机会对非 VPC CIDR 目的 IP 执行 L3 强制路由，
# 必须通过 VPC 路由表将 0.0.0.0/0 指向堡垒机 ENI，才能让内部 ECS
# 的外网流量到达堡垒机进行 NAT 转发。
resource "alicloud_route_entry" "nat_gateway" {
  route_table_id        = alicloud_vpc.vpc.route_table_id
  destination_cidrblock = "0.0.0.0/0"
  nexthop_type          = "NetworkInterface"
  nexthop_id            = local.bastion_eni_id
}

# 堡垒机 ENI ID（用于路由条目和源目检查）
locals {
  bastion_eni_id = [
    for k, v in alicloud_instance.ecs : v.network_interface_id
    if var.ecs_instances[k].public_ip
  ][0]
}

# 关闭堡垒机的源/目的检查（允许转发非本机流量）
# 阿里云 ECS 默认启用此检查，会丢弃目标 IP 不是本机的所有入站流量。
resource "null_resource" "disable_src_dst_check" {
  triggers = {
    eni_id = local.bastion_eni_id
  }

  provisioner "local-exec" {
    command = <<-EOF
      aliyun ecs ModifyNetworkInterfaceAttribute \
        --NetworkInterfaceId '${local.bastion_eni_id}' \
        --SourceDestCheck false \
        --region '${var.alicloud_region}' 2>&1 || true
    EOF
    interpreter = ["bash", "-c"]
  }
}
