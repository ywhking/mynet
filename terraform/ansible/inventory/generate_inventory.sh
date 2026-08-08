#!/bin/bash
# ============================================================
# Ansible Dynamic Inventory Generator
# 从 Terraform 输出中解析 ECS 实例信息，生成 Ansible inventory JSON
#
# 分组:
#   nat_gateway  堡垒机（is_bastion = true，唯一有独立公网 IP 直连的主机）
#   public       公网设备（非堡垒机，公网子网；有独立公网 IP 的直连，否则走跳板）
#   internal     内网设备（内网子网，通过堡垒机 ProxyJump 访问）
#
# 使用方法:
#   ./generate_inventory.sh --list          # 输出完整 inventory
#   ./generate_inventory.sh --host <name>   # 输出单台主机变量（可选）
#   ./generate_inventory.sh --write [路径]  # 固化为静态 inventory（hosts.yml）
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
KEY_DIR="$TERRAFORM_DIR/keys"

# 检查 jq 是否可用
if ! command -v jq &>/dev/null; then
    echo '{"_meta":{"hostvars":{}}}' >&2
    echo "ERROR: jq is required but not installed. Install with: apt-get install jq" >&2
    exit 1
fi

# 从 terraform output 获取状态
# 成功: 输出 JSON → stdout
# 失败: 输出空 inventory JSON → stdout (调用方直接使用并退出)
get_tf_output() {
    cd "$TERRAFORM_DIR"
    # 检查 state 文件是否存在且有资源
    if [[ ! -f "terraform.tfstate" ]] || ! jq -e '.resources | length > 0' terraform.tfstate 2>/dev/null >/dev/null; then
        echo "WARN: Terraform state is empty or has no resources. Run 'terraform apply' first." >&2
        echo '{"_empty":true}'
        return 0
    fi
    terraform output -json 2>/dev/null || {
        echo "ERROR: 'terraform output' failed. Run 'terraform apply' first." >&2
        echo '{"_empty":true}'
        return 1
    }
}

# 从 ecs_key_pair_names 推导私钥路径
#   key_pair_name = "KEY-<instance_name>"  →  keys/KEY-<instance_name>
key_file_for() {
    local instance_name="$1"
    echo "$KEY_DIR/KEY-${instance_name}"
}

# bash 数组 → JSON 字符串数组
to_json_array() {
    local -n arr="$1"
    if ((${#arr[@]} == 0)); then
        echo "[]"
        return 0
    fi
    printf '%s\n' "${arr[@]}" | jq -R -s -c 'split("\n") | map(select(. != ""))'
}

# 生成完整 inventory JSON
generate_inventory() {
    local tf_output
    tf_output=$(get_tf_output)

    # 检查是否为空状态标记
    if echo "$tf_output" | jq -e '._empty // false' >/dev/null 2>&1; then
        echo '{"nat_gateway":{"hosts":[],"vars":{}},"public":{"hosts":[],"vars":{}},"internal":{"hosts":[],"vars":{}},"_meta":{"hostvars":{}}}'
        return 0
    fi

    # 提取关键字段
    local bastion_name bastion_public_ip bastion_private_ip vpc_cidr
    bastion_name=$(echo "$tf_output" | jq -r '.bastion_name.value // ""')
    bastion_public_ip=$(echo "$tf_output" | jq -r '.bastion_public_ip.value // ""')
    bastion_private_ip=$(echo "$tf_output" | jq -r '.bastion_private_ip.value // ""')
    vpc_cidr=$(echo "$tf_output" | jq -r '.vpc_cidr.value // "172.16.0.0/16"')

    if [[ -z "$bastion_name" || -z "$bastion_public_ip" || "$bastion_public_ip" == "null" ]]; then
        echo '{"nat_gateway":{"hosts":[],"vars":{}},"public":{"hosts":[],"vars":{}},"internal":{"hosts":[],"vars":{}},"_meta":{"hostvars":{}}}'
        echo "WARN: No bastion (is_bastion ECS) found in terraform outputs." >&2
        exit 0
    fi

    # 解析所有 ECS 实例 + 公网 IP 设备（有独立公网 IP 的非堡垒机）
    local all_instances public_ip_map
    all_instances=$(echo "$tf_output" | jq -r '.ecs_private_ips.value | keys[]')
    public_ip_map=$(echo "$tf_output" | jq -c '.ecs_public_ips.value // {}')

    # 分组: nat_gateway（堡垒机）/ public（公网设备）/ internal（内网设备）
    local public_hosts=() internal_hosts=()
    while IFS= read -r instance_name; do
        [[ -z "$instance_name" || "$instance_name" == "$bastion_name" ]] && continue
        if echo "$public_ip_map" | jq -e --arg n "$instance_name" 'has($n)' >/dev/null 2>&1; then
            public_hosts+=("$instance_name")
        else
            internal_hosts+=("$instance_name")
        fi
    done <<< "$all_instances"

    # ---- 构建 hostvars ----
    local hostvars_json=""

    # 堡垒机（NAT 网关）hostvars — 直连公网 IP
    local bastion_key
    bastion_key=$(key_file_for "$bastion_name")
    hostvars_json+="\"$bastion_name\":{"
    hostvars_json+="\"ansible_host\":\"$bastion_public_ip\","
    hostvars_json+="\"ansible_user\":\"root\","
    hostvars_json+="\"ansible_ssh_private_key_file\":\"$bastion_key\","
    hostvars_json+="\"ansible_ssh_common_args\":\"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null\","
    hostvars_json+="\"vpc_cidr\":\"$vpc_cidr\","
    hostvars_json+="\"bastion_private_ip\":\"$bastion_private_ip\""
    hostvars_json+="}"

    # 其余 ECS hostvars: 有独立公网 IP 直连；否则通过堡垒机 ProxyJump 访问
    while IFS= read -r instance_name; do
        [[ -z "$instance_name" || "$instance_name" == "$bastion_name" ]] && continue
        local priv_ip pub_ip
        priv_ip=$(echo "$tf_output" | jq -r ".ecs_private_ips.value[\"$instance_name\"] // \"\"")
        if [[ -z "$priv_ip" || "$priv_ip" == "null" ]]; then
            continue
        fi
        pub_ip=$(echo "$public_ip_map" | jq -r --arg n "$instance_name" '.[$n] // ""')
        if [[ -z "$pub_ip" || "$pub_ip" == "null" ]]; then
            pub_ip=""
        fi
        local instance_key
        instance_key=$(key_file_for "$instance_name")

        hostvars_json+=",\"$instance_name\":{"
        hostvars_json+="\"ansible_host\":\"${pub_ip:-$priv_ip}\","
        hostvars_json+="\"ansible_user\":\"root\","
        hostvars_json+="\"ansible_ssh_private_key_file\":\"$instance_key\","
        if [[ -n "$pub_ip" ]]; then
            # 有独立公网 IP → 直连
            hostvars_json+="\"ansible_ssh_common_args\":\"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null\","
        else
            # 无公网 IP → 通过堡垒机跳板访问
            # ProxyCommand 值必须加单引号，否则 Ansible 会按空格分割参数导致 SSH 报错
            hostvars_json+="\"ansible_ssh_common_args\":\"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand='ssh -i $bastion_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W $priv_ip:22 root@$bastion_public_ip'\","
        fi
        hostvars_json+="\"gateway_ip\":\"$bastion_private_ip\","
        hostvars_json+="\"vpc_cidr\":\"$vpc_cidr\""
        hostvars_json+="}"
    done <<< "$all_instances"

    # ---- 组装最终 JSON ----
    local nat_hosts_json public_hosts_json internal_hosts_json
    nat_hosts_json="[\"$bastion_name\"]"
    public_hosts_json=$(to_json_array public_hosts)
    internal_hosts_json=$(to_json_array internal_hosts)

    cat <<EOF
{
  "nat_gateway": {
    "hosts": $nat_hosts_json,
    "vars": {}
  },
  "public": {
    "hosts": $public_hosts_json,
    "vars": {}
  },
  "internal": {
    "hosts": $internal_hosts_json,
    "vars": {}
  },
  "_meta": {
    "hostvars": {
      $hostvars_json
    }
  }
}
EOF
}

# ---- 生成静态 YAML inventory 文件 ----
# 将动态 inventory 固化为静态文件（默认 inventory/hosts.yml），
# ansible.cfg 默认指向该文件，后续 ansible 命令无需再指定 -i。
# 资源变更（terraform apply/destroy）后需重新执行本命令刷新。
# 用法: ./generate_inventory.sh --write [输出路径]
write_static_inventory() {
    local out_path="${1:-$SCRIPT_DIR/hosts.yml}"
    local inventory_json hosts_count
    inventory_json=$(generate_inventory)

    # 没有堡垒机（未 apply 或 state 为空）→ 拒绝生成，避免产生错误的空文件
    if ! echo "$inventory_json" | jq -e '.nat_gateway.hosts // [] | length > 0' >/dev/null 2>&1; then
        echo "ERROR: 无法生成静态 inventory — 未找到堡垒机（nat_gateway 组为空）。" >&2
        echo "       请先在 terraform 目录执行 terraform apply，然后重试。" >&2
        return 1
    fi

    {
        echo "# ============================================================"
        echo "# 静态 Ansible Inventory — 自动生成，请勿手动编辑"
        echo "# 来源: ./inventory/generate_inventory.sh --write"
        echo "# 资源变更（terraform apply/destroy）后请重新生成"
        echo "# ============================================================"
        echo "all:"
        echo "  children:"
        echo "$inventory_json" | jq -r '
            ["nat_gateway", "public", "internal"][] as $g |
            "    \($g):",
            "      hosts:",
            (.[$g].hosts[] as $h |
                "        \($h | @json):",
                (._meta.hostvars[$h] | to_entries[] |
                    "          \(.key): \(.value | @json)")
            )
        '
    } > "$out_path"

    hosts_count=$(echo "$inventory_json" | jq -r '[.nat_gateway.hosts[], .public.hosts[], .internal.hosts[]] | length')
    echo "✅ 静态 inventory 已生成: $out_path"
    echo "   主机数: $hosts_count"
    echo "   堡垒机: $(echo "$inventory_json" | jq -r '.nat_gateway.hosts | join(", ")')"
    echo "   公网机: $(echo "$inventory_json" | jq -r '.public.hosts | join(", ")')"
    echo "   内部机: $(echo "$inventory_json" | jq -r '.internal.hosts | join(", ")')"
    echo ""
    echo "后续命令无需再指定 -i："
    echo "  ansible all -m ping"
    echo "  ansible-playbook playbooks/setup-all.yml"
}

# ---- 主入口 ----
case "${1:-}" in
    --list)
        generate_inventory
        ;;
    --host)
        # Ansible 要求能处理 --host <name>，我们已通过 _meta 提供所有 hostvars
        echo '{}'
        ;;
    --write)
        # 生成静态 YAML inventory，简化后续 ansible 命令
        write_static_inventory "${2:-}"
        ;;
    *)
        echo "Usage: $0 --list | --host <hostname> | --write [输出路径]" >&2
        exit 1
        ;;
esac
