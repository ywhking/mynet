#!/bin/bash
# ============================================================
# 脚本名称: set_nat_gateway.sh
# 功能描述: 将当前 ECS 的默认路由指向 NAT 网关 ECS
# 适用系统: Ubuntu 24.04 (Netplan)
# 使用方法: sudo bash set_nat_gateway.sh <NAT网关内网IP> [内网网段]
#
# 示例:
#   sudo bash set_nat_gateway.sh 172.16.1.10
#   sudo bash set_nat_gateway.sh 172.16.1.10 172.16.0.0/16
# ============================================================

set -euo pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---- 参数解析 ----
if [[ $# -lt 1 ]]; then
    log_error "用法: $0 <NAT网关内网IP> [内网网段]"
    log_error "示例: $0 172.16.1.10 172.16.0.0/16"
    exit 1
fi

GATEWAY_IP="$1"
LOCAL_SUBNET="${2:-172.16.0.0/16}"

# ---- 检查 root 权限 ----
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 权限运行！"
    echo "请使用: sudo bash $0 $GATEWAY_IP"
    exit 1
fi

# ---- 获取当前默认路由的接口和网关 ----
CURRENT_DEFAULT=$(ip route show default 2>/dev/null | head -1 || true)
if [[ -z "$CURRENT_DEFAULT" ]]; then
    # 没有默认路由，获取主接口
    PRIMARY_IF=$(ip route show | grep '^default\|^[0-9]' | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [[ -z "$PRIMARY_IF" ]]; then
        PRIMARY_IF=$(ip -o link show | grep -v 'lo:' | head -1 | awk -F': ' '{print $2}')
    fi
    OLD_GATEWAY=""
else
    PRIMARY_IF=$(echo "$CURRENT_DEFAULT" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    OLD_GATEWAY=$(echo "$CURRENT_DEFAULT" | awk '{print $3}')
fi

log_info "主网络接口: $PRIMARY_IF"
if [[ -n "$OLD_GATEWAY" ]]; then
    log_info "当前默认网关: $OLD_GATEWAY"
fi
log_info "NAT 网关地址: $GATEWAY_IP"

# ---- 1. 立即生效：添加路由 ----
log_info "配置路由规则..."

# 确保到 NAT 网关的直接路由存在（同网段时已有直连路由，此处为保险）
if ip route get "$GATEWAY_IP" &>/dev/null; then
    log_info "到 NAT 网关 ($GATEWAY_IP) 的路由可达"
else
    log_warn "NAT 网关 ($GATEWAY_IP) 不可达，请检查网络连通性"
fi

# 删除旧默认路由并添加新路由
if [[ -n "$CURRENT_DEFAULT" ]]; then
    log_info "移除当前默认路由: $CURRENT_DEFAULT"
    ip route del default 2>/dev/null || true
fi

# 添加新的默认路由指向 NAT 网关
ip route add default via "$GATEWAY_IP" dev "$PRIMARY_IF" 2>/dev/null || {
    log_error "无法添加默认路由 via $GATEWAY_IP"
    log_error "请确认 NAT 网关 ECS 的网络可达性"
    exit 1
}
log_info "默认路由已设置为: via $GATEWAY_IP dev $PRIMARY_IF"

# ---- 2. 测试连通性 ----
log_info "测试外网连通性..."
if ping -c 2 -W 3 8.8.8.8 &>/dev/null; then
    log_info "✓ 外网连通性正常（通过 NAT 网关）"
elif ping -c 2 -W 3 114.114.114.114 &>/dev/null; then
    log_info "✓ 外网连通性正常（通过 NAT 网关）"
else
    log_warn "✗ 外网 ping 测试失败，请检查 NAT 网关配置"
    log_warn "  可能原因: NAT 网关未开启 IP 转发 / iptables 规则未正确配置"
fi

# ---- 3. 持久化配置 ----
log_info "持久化路由配置..."

# 方法: 使用 Netplan (Ubuntu 24.04 默认网络管理器)
NETPLAN_FILE="/etc/netplan/99-nat-gateway-route.yaml"

cat > "$NETPLAN_FILE" << NETPLAN_EOF
# NAT 网关路由配置（由 set_nat_gateway.sh 生成）
# 将默认路由指向 NAT 网关 ECS ($GATEWAY_IP)
# metric: 50 — 低于云初始化 DHCP 默认路由的 metric(100)，
# 保证重启后默认路由确定为 NAT 网关，而非在两条默认路由间不确定。
network:
  version: 2
  ethernets:
    ${PRIMARY_IF}:
      routes:
        - to: default
          via: ${GATEWAY_IP}
          metric: 50
NETPLAN_EOF

# 设置安全权限
chmod 600 "$NETPLAN_FILE"

log_info "Netplan 配置文件已写入: $NETPLAN_FILE"

# 应用 Netplan 配置
if command -v netplan &>/dev/null; then
    netplan apply 2>/dev/null && log_info "Netplan 配置已应用" || log_warn "Netplan apply 失败，但路由已即时生效"
else
    log_warn "netplan 命令不可用，路由仅在当前运行状态生效"
    log_warn "重启后请手动执行: ip route add default via $GATEWAY_IP dev $PRIMARY_IF"
fi

# ---- 完成 ----
echo ""
echo "=========================================="
echo "  网关配置完成"
echo "=========================================="
echo "  NAT 网关:  $GATEWAY_IP"
echo "  网络接口:  $PRIMARY_IF"
echo "  持久化文件: $NETPLAN_FILE"
echo ""
echo "  验证: ping 8.8.8.8"
echo "  回滚: sudo rm $NETPLAN_FILE && netplan apply"
echo "=========================================="
