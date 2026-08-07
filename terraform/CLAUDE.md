# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Terraform project that provisions Alibaba Cloud (Alicloud) resources:

- **Resource Group** (`rg.tf`) — Resource group via `alicloud_resource_manager_resource_group`, name from input parameter.
- **Provider** (`main.tf`) — Alicloud provider, `alicloud_region` (地域) required.
- **VPC** (`vpc.tf`) — VPC, one VSwitch, security group (SSH/HTTP/HTTPS/ICMP ingress rules), route entry for NAT traffic forwarding, and source/dest check disable on the bastion ENI.
- **ECS** (`ecs.tf`) — Dynamic N instances (Ubuntu 24.04 via `data.alicloud_images`), exactly one with public IP (10Mbps). SSH key pairs auto-generated locally via `data.external` calling `scripts/generate_key.sh`, one key pair per ECS.

## Scripts

The `scripts/` directory contains shell scripts used by Terraform and Ansible:

| Script | Called By | Purpose |
|--------|-----------|---------|
| `scripts/generate_key.sh` | Terraform `data.external.ssh_key` | Generates SSH key pair locally in `keys/` if not already present; returns public key to Terraform |
| `scripts/install_nat_gateway.sh` | Ansible playbook (uploaded to bastion) | Interactive script that configures iptables NAT (MASQUERADE/SNAT + optional DNAT), IP forwarding, and persistence on the bastion ECS |
| `scripts/set_nat_gateway.sh` | Ansible playbook (uploaded to internal ECS) | Sets the default route on an internal ECS to point at the NAT gateway; persists via Netplan (Ubuntu 24.04) |

## Required Input Parameters

| 参数 | 说明 | 示例值 |
|------|------|--------|
| `alicloud_region` | 地域 | `cn-wulanchabu` |
| `resource_group_name` | 资源组名称 | `tf-resource-group` |
| `ecs_instances` | ECS 实例列表（map），key 为实例名称，`public_ip` 必须且只能有一个为 `true` | 见下方示例 |

## Optional Input Parameters

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `vpc_cidr` | VPC IPv4 地址范围 | `172.16.0.0/16` |
| `vswitch_zone` | VSwitch 可用区 | `cn-wulanchabu-a` |
| `sg_name` | 安全组名称 | `tf-sg-default` |
| `ecs_instance_type` | ECS 实例类型 | `ecs.t6-c1m2.large` |
| `ecs_ssh_public_key` | SSH 公钥内容（留空则本地自动生成） | `""` |

### `ecs_instances` 格式示例

```hcl
ecs_instances = {
  "web-server" = {
    host_name = "web"
    public_ip = true   # 有且只能有一个为 true
  }
  "db-server" = {
    host_name = "db"
    public_ip = false
  }
}
```

密钥对名称自动生成为 `KEY-<实例名称>`，每个 ECS 独立一个密钥对。

Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in values:

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your values
```

## Provider Credentials

The Alicloud provider auto-reads credentials from environment variables — no explicit variable definitions needed:

```bash
export ALICLOUD_ACCESS_KEY="your-access-key-id"
export ALICLOUD_SECRET_KEY="your-secret-access-key"
export ALICLOUD_REGION="cn-wulanchabu"  # optional, or set via var.alicloud_region in .tfvars
```

After setting them, run `terraform plan` / `terraform apply` as normal.

## Terraform Outputs

| Output | Description |
|--------|-------------|
| `ecs_key_pair_names` | SSH key pair names (keyed by instance name) |
| `ecs_public_ips` | Public IPs of the bastion ECS |
| `ecs_private_ips` | Private IPs of all ECS instances |
| `bastion_name` | Name of the bastion (NAT gateway) ECS |
| `bastion_public_ip` | Public IP of the bastion ECS |
| `bastion_private_ip` | Private IP of the bastion ECS |
| `vpc_cidr` | VPC CIDR block |

## Commands

```bash
# Initialize Terraform (download providers, set up backend)
terraform init

# Preview changes before applying
terraform plan

# Apply configuration
terraform apply

# Destroy all managed resources
terraform destroy

# Format code
terraform fmt

# Validate configuration syntax
terraform validate
```

## Ansible — NAT 网关自动化配置

Ansible 用于在 Terraform 创建的 ECS 实例上自动配置 NAT 网关和路由。

### 目录结构

```
ansible/
├── ansible.cfg                          # Ansible 配置（默认 inventory 指向 hosts.yml、SSH 跳板等）
├── inventory/
│   ├── generate_inventory.sh            # inventory 脚本（--list 动态输出 / --write 生成静态 hosts.yml）
│   └── hosts.yml                        # 静态 inventory（自动生成，请勿手动编辑）
├── playbooks/
│   └── setup-all.yml                    # 主 playbook：NAT 网关 + 内部 ECS 网关配置
└── group_vars/
    └── all.yml                          # （可选）全局变量覆盖
```

### 前置条件

```bash
# 1. 安装 Ansible 和 jq
sudo apt-get install ansible jq -y

# 2. 先执行 terraform apply（确保资源已创建）
terraform apply

# 3. 生成静态 inventory（资源变更后需重新执行此命令刷新）
cd ansible
./inventory/generate_inventory.sh --write
```

### 使用方法

静态 inventory 由 `--write` 生成后，**所有命令无需再指定 `-i`**（ansible.cfg 默认已指向 `inventory/hosts.yml`）：

```bash
cd ansible

# 测试连通性
ansible all -m ping

# 预览所有变更（dry-run）
ansible-playbook playbooks/setup-all.yml --check

# 执行完整配置
ansible-playbook playbooks/setup-all.yml

# 仅配置 NAT 网关（堡垒机）
ansible-playbook playbooks/setup-all.yml --tags nat

# 仅配置内部 ECS 网关
ansible-playbook playbooks/setup-all.yml --tags client
```

> **注意**：`terraform apply` / `terraform destroy` 之后，必须重新执行
> `./inventory/generate_inventory.sh --write` 刷新静态 inventory，
> 否则 IP 和主机列表会过期。

### Playbook 执行流程

```
Play 1: nat_gateway 组
  ├─ 检测主网络接口（eth0）
  ├─ 上传 install_nat_gateway.sh
  ├─ 兼容单网卡场景（注释 WAN==LAN 检查）
  ├─ 修复 iptables-nft 兼容性（-t 参数前置）
  ├─ 移除 pipefail（避免命令替换中管道失败导致脚本退出）
  ├─ 消除 WAN_CONN_OK 竞态条件
  ├─ 动态构建非交互式答案序列（处理私有IP/外网连通性条件提示）
  ├─ 执行 NAT 网关脚本（MASQUERADE 模式）
  └─ 验证 iptables NAT 规则 + IP 转发状态

Play 2: internal 组（通过堡垒机 ProxyJump 访问）
  ├─ 上传 set_nat_gateway.sh
  ├─ 将默认路由指向 NAT 网关 ECS 内网 IP
  ├─ 持久化到 Netplan（Ubuntu 24.04）
  └─ 验证路由 + 外网连通性

Play 3: all 组
  └─ 输出配置摘要
```

### 关键技术决策

| 决策 | 说明 |
|------|------|
| **MASQUERADE** | 云环境中公网 IP 由云平台动态 NAT 映射，适合用 MASQUERADE 而非固定 SNAT |
| **单网卡 NAT** | 阿里云 VPC 中 ECS 只有一个 ENI，入站/出站流量都在 eth0 上 |
| **Netplan 持久化** | Ubuntu 24.04 使用 Netplan 管理网络，路由配置写入 `/etc/netplan/99-nat-gateway-route.yaml` |
| **动态解析 + 静态固化** | `generate_inventory.sh` 从 `terraform output -json` 解析 IP 和密钥路径；`--write` 固化为 `hosts.yml`，Ansible 走静态 inventory（命令无需 `-i`），资源变更后重新生成即可 |

### 回滚

```bash
# NAT 网关回滚（堡垒机上执行）
ssh -i keys/KEY-<bastion-name> root@<bastion-public-ip> 'bash /root/rollback_nat.sh'

# 内部 ECS 回滚（通过堡垒机跳板）
ssh -J root@<bastion-public-ip> root@<internal-ecs-ip> \
  'rm /etc/netplan/99-nat-gateway-route.yaml && netplan apply'
```

## Architecture

- **Provider**: Alicloud (`hashicorp/alicloud`, pinned to `1.285.0` in `.terraform.lock.hcl`)
- **Multi-file configuration**: Provider in `main.tf`, VPC in `vpc.tf`, ECS in `ecs.tf`, Resource Group in `rg.tf`.
- **Required variables** (`alicloud_region`, `resource_group_name`, `ecs_instances`) have no defaults — must be set via `.tfvars` or `-var`.
- **Other variables** have defaults — override via `.tfvars` or `-var` CLI flags.
- **External dependencies**: The `null_resource.disable_src_dst_check` in `vpc.tf` requires the `aliyun` CLI to be installed and authenticated.

### Resource Graph

```
data.alicloud_images.ubuntu                          data.external.ssh_key["<name>"]
  │                                                     │ (calls scripts/generate_key.sh)
  │                                                     ▼
  │                                       alicloud_key_pair.per_ecs["<name>"]
  │                                         │
  ▼                                         │
alicloud_resource_manager_resource_group.rg │
  │                                         │
  ├─→ alicloud_vpc.vpc                      │
  │     │                                   │
  │     ├─→ alicloud_vswitch.vswitch ──→ alicloud_instance.ecs["<name>"]  (N 台动态，for_each)
  │     │                                                               │
  │     ├─→ alicloud_security_group.sg ──→ allow_ssh / allow_http / allow_https / allow_icmp
  │     │
  │     ├─→ alicloud_route_entry.nat_gateway  (0.0.0.0/0 → 堡垒机 ENI)
  │     │     │
  │     │     └─→ local.bastion_eni_id  (from alicloud_instance.ecs[bastion].network_interface_id)
  │     │
  │     └─→ null_resource.disable_src_dst_check  (aliyun CLI: 关闭堡垒机源/目的检查)
  │
  └─ (all resources use resource_group_id to reference this group)
```

**Key architectural details:**

- **VPC route entry**: Alibaba Cloud VPC virtual switches perform L3 forced routing for destinations outside the VPC CIDR. The `alicloud_route_entry.nat_gateway` routes `0.0.0.0/0` to the bastion's ENI so internal ECS traffic reaches the bastion for NAT forwarding.
- **Source/dest check**: Alibaba Cloud ECS instances have source/destination checking enabled by default (drops packets not destined for the instance's own IP). The `null_resource.disable_src_dst_check` uses the `aliyun` CLI to disable this on the bastion ENI, allowing it to forward traffic from internal ECS instances.
- **SSH key generation**: `scripts/generate_key.sh` is called as a Terraform `data.external` source. If `ecs_ssh_public_key` is provided, it uses that key; otherwise it generates a new RSA 4096-bit key pair in `keys/KEY-<instance_name>` (idempotent — skips if the file already exists).
- **Ubuntu image**: `data.alicloud_images.ubuntu` queries for the latest Ubuntu 24.04 image matching `^ubuntu_24_04_x64_20G_alibase_`.
- **Exactly one public IP**: The `ecs_instances` variable has a `validation` block enforcing that exactly one instance has `public_ip = true`.
