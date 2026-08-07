#!/bin/bash
# ============================================================
# 脚本名称: install_nat_gateway.sh
# 功能描述: 将Linux服务器配置为NAT网关，支持SNAT和DNAT
# 适用系统: Ubuntu/Debian/CentOS/RHEL/Rocky/Alma/Oracle
# 使用方法: sudo bash install_nat_gateway.sh
# ============================================================

set -euo pipefail

# 确保关键命令在 PATH 中
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ============================================================
# 颜色定义与日志函数
# ============================================================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ============================================================
# 全局状态变量（供 trap 和回滚使用）
# ============================================================
BACKUP_FILE=""       # 安装前 iptables 备份文件路径
RULES_APPLIED=false  # 是否已成功应用 NAT 规则
ORIGINAL_FORWARD=""  # 安装前 net.ipv4.ip_forward 原始值
APPLY_STARTED=false  # 是否已开始应用规则（用于 trap 判断恢复粒度）
WAN_IF=""            # 外网接口
WAN_IP=""            # 外网IP
LAN_IF=""            # 内网接口
LAN_IP=""            # 内网IP
LAN_SUBNET=""        # 内网网段
SNAT_TYPE=""         # SNAT 或 MASQUERADE
DNAT_ENTRIES=()      # DNAT 规则数组

# ============================================================
# 辅助函数
# ============================================================
is_yes() {
    [[ "${1:-}" =~ ^[Yy]$ ]]
}

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]
}

is_private_ip() {
    local ip="$1"
    local IFS='.'; local -a octets
    read -ra octets <<< "$ip"
    # 10.0.0.0/8
    [[ ${octets[0]} -eq 10 ]] && return 0
    # 172.16.0.0/12
    [[ ${octets[0]} -eq 172 && ${octets[1]} -ge 16 && ${octets[1]} -le 31 ]] && return 0
    # 192.168.0.0/16
    [[ ${octets[0]} -eq 192 && ${octets[1]} -eq 168 ]] && return 0
    # 100.64.0.0/10 (CGNAT)
    [[ ${octets[0]} -eq 100 && ${octets[1]} -ge 64 && ${octets[1]} -le 127 ]] && return 0
    return 1
}

_get_default_policy() {
    local chain="$1"
    iptables -L "$chain" -n 2>/dev/null | head -1 | grep -oP 'policy \K[A-Z]+' || echo "ACCEPT"
}

_pkg_manager() {
    # 返回可用的包管理器命令
    if command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v apt-get &>/dev/null; then
        echo "apt-get"
    else
        echo ""
    fi
}

# 安全的交互式读取（正确处理 Ctrl+D / EOF）
safe_read() {
    local var_name="$1"
    local prompt="$2"
    read -r -p "$prompt" "$var_name" || {
        echo ""
        log_error "检测到 EOF (Ctrl+D)，脚本退出"
        exit 1
    }
}

# 信号处理 — 中断时尝试恢复
cleanup_on_interrupt() {
    echo ""
    log_warn "脚本被中断（SIGINT/SIGTERM），尝试恢复..."
    if $APPLY_STARTED; then
        if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
            log_info "正在从备份恢复 iptables 规则: $BACKUP_FILE"
            iptables-restore < "$BACKUP_FILE" 2>/dev/null || {
                log_warn "规则恢复失败，设置 ACCEPT 默认策略防止锁死"
            }
        fi
        # 确保默认策略为 ACCEPT（防止 SSH 锁死）
        iptables -P INPUT ACCEPT 2>/dev/null || true
        iptables -P FORWARD ACCEPT 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    fi
    if [[ -n "$ORIGINAL_FORWARD" ]]; then
        sysctl -w "net.ipv4.ip_forward=$ORIGINAL_FORWARD" 2>/dev/null || true
    fi
    log_info "清理完成"
    exit 1
}
trap cleanup_on_interrupt INT TERM

# ============================================================
# 预检查函数
# ============================================================

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root权限运行！"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

# 检测系统类型
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测操作系统类型（/etc/os-release 不存在）！"
        exit 1
    fi
    . /etc/os-release
    if [[ -z "${ID:-}" ]]; then
        log_error "/etc/os-release 缺少 ID 字段，无法确定系统类型！"
        exit 1
    fi
    OS="${ID}"
    OS_LIKE="${ID_LIKE:-}"
    log_info "检测到系统: $OS${VERSION_ID:+ $VERSION_ID}"
}

# 检查依赖命令
check_dependencies() {
    log_step "检查依赖命令..."
    local -a missing=()

    for cmd in iptables iptables-save iptables-restore ip sysctl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少必要的命令: ${missing[*]}"
        log_error "请先安装: apt-get install iptables iproute2 procps (Debian/Ubuntu)"
        log_error "        或: dnf install iptables iproute procps-ng (CentOS/RHEL)"
        exit 1
    fi
    log_info "所有依赖命令已就绪"
}

# 检查冲突的网络服务
check_conflicting_services() {
    log_step "检查冲突的网络服务..."
    local -a conflicts=()

    if command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q '.'; then
        conflicts+=("nftables (检测到活动规则集)")
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        conflicts+=("firewalld")
    fi
    if systemctl is-active --quiet ufw 2>/dev/null; then
        conflicts+=("ufw")
    fi

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        log_warn "检测到以下可能与 iptables 规则冲突的服务："
        for svc in "${conflicts[@]}"; do
            echo "  - $svc"
        done
        log_warn "建议先停止或禁用这些服务，否则规则可能不生效或被覆盖"
    else
        log_info "未检测到冲突服务"
    fi
}

# ============================================================
# 信息收集函数
# ============================================================

show_interfaces() {
    log_step "当前网络接口信息："
    echo "=========================================="
    # 兼容旧版 iproute2（-br 标志在 v4.11+ 才可用）
    if ip -br addr show &>/dev/null; then
        ip -br addr show | grep -v "^lo" | column -t
    else
        ip -4 -o addr show | grep -v " lo " | awk '{print $2, $4}' | column -t
    fi
    echo "=========================================="
    echo ""
}

# 获取用户输入的接口和网段
get_network_info() {
    # ----- 外网接口 -----
    safe_read WAN_IF "请输入外网接口名称 (如 eth0, ens33): "
    if [[ -z "$WAN_IF" ]]; then
        log_error "外网接口不能为空！"
        exit 1
    fi
    if ! ip link show "$WAN_IF" &>/dev/null; then
        log_error "接口 $WAN_IF 不存在！"
        exit 1
    fi

    # 获取外网IP（单个 awk 调用替代 awk|cut|head 管道链）
    WAN_IP=$(ip -4 -o addr show "$WAN_IF" | awk '{split($4,a,"/"); print a[1]; exit}')
    if [[ -z "$WAN_IP" ]]; then
        log_error "无法获取 $WAN_IF 的IP地址，请检查接口配置！"
        exit 1
    fi
    log_info "外网接口IP: $WAN_IP"

    # RFC 1918 私有地址检查
    if is_private_ip "$WAN_IP"; then
        log_warn "外网IP $WAN_IP 是私有地址（RFC 1918 / CGNAT）"
        log_warn "如果此服务器在云环境中使用 1:1 NAT，SNAT 到私有地址可能导致外网不通"
        safe_read WAN_PRIVATE_OK "是否仍要继续？(y/n): "
        if ! is_yes "$WAN_PRIVATE_OK"; then
            log_info "用户取消操作"
            exit 0
        fi
    fi

    # 外网连通性检查
    log_info "正在检查外网连通性..."
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null || ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
        log_info "外网连通性正常"
    else
        log_warn "无法 ping 通外网地址（8.8.8.8 / 114.114.114.114），请确认 WAN 接口已正确配置"
        safe_read WAN_CONN_OK "是否仍要继续？(y/n): "
        if ! is_yes "$WAN_CONN_OK"; then
            log_info "用户取消操作"
            exit 0
        fi
    fi

    # ----- 内网接口 -----
    safe_read LAN_IF "请输入内网接口名称 (如 eth1, ens34): "
    if [[ -z "$LAN_IF" ]]; then
        log_error "内网接口不能为空！"
        exit 1
    fi
    if ! ip link show "$LAN_IF" &>/dev/null; then
        log_error "接口 $LAN_IF 不存在！"
        exit 1
    fi

    # 检查内外网接口不能相同
    if [[ "$WAN_IF" == "$LAN_IF" ]]; then
        log_error "外网接口和内网接口不能相同（都选择了 $WAN_IF）！"
        log_error "NAT 网关至少需要两个网络接口"
        exit 1
    fi

    # 获取内网IP（用于后续摘要中的网关推荐）
    LAN_IP=$(ip -4 -o addr show "$LAN_IF" | awk '{split($4,a,"/"); print a[1]; exit}')
    if [[ -z "$LAN_IP" ]]; then
        log_warn "无法获取 $LAN_IF 的IP地址，后续摘要将无法显示正确的网关地址"
    else
        log_info "内网接口IP: $LAN_IP"
    fi

    # ----- 内网网段 -----
    safe_read LAN_SUBNET "请输入内网网段 (如 192.168.1.0/24): "
    if [[ -z "$LAN_SUBNET" ]]; then
        log_error "内网网段不能为空！"
        exit 1
    fi

    # 验证网段格式 — 要求前缀长度 >= 8（拒绝 /0~/7）
    if ! [[ "$LAN_SUBNET" =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])/([89]|[12][0-9]|3[0-2])$ ]]; then
        log_error "网段格式错误！正确格式如: 192.168.1.0/24（前缀长度须 >= 8）"
        exit 1
    fi

    # LAN 子网可达性提示
    if [[ -n "$LAN_IP" ]]; then
        if ! ip route get "$LAN_IP" &>/dev/null; then
            log_warn "$LAN_IF 的路由不可达，请检查接口配置"
        fi
    fi
}

# 选择SNAT模式
select_snat_mode() {
    echo ""
    log_step "请选择SNAT模式："
    echo "  1) SNAT        (固定公网IP，性能更好)"
    echo "  2) MASQUERADE  (动态IP，如PPPoE拨号)"
    local snat_mode
    safe_read snat_mode "请选择 [1-2]: "

    case $snat_mode in
        1) SNAT_TYPE="SNAT" ;;
        2) SNAT_TYPE="MASQUERADE" ;;
        *) log_error "无效选择！"; exit 1 ;;
    esac
    log_info "选择的SNAT模式: $SNAT_TYPE"
}

# 配置DNAT端口转发
configure_dnat() {
    local proto ext_port target_ip target_port continue_yn
    DNAT_ENTRIES=()

    echo ""
    local config_dnat
    safe_read config_dnat "是否配置DNAT端口转发？(y/n): "
    if ! is_yes "$config_dnat"; then
        log_info "跳过DNAT配置"
        return
    fi

    while true; do
        echo ""
        log_step "添加端口转发规则："
        safe_read proto "请输入协议 (tcp/udp): "
        if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
            log_warn "协议必须是 tcp 或 udp！"
            continue
        fi
        safe_read ext_port "请输入外部端口 (如 80): "
        safe_read target_ip "请输入内网目标IP (如 192.168.1.100): "
        safe_read target_port "请输入目标端口 (如 80): "

        # 验证输入
        if [[ -z "$ext_port" || -z "$target_ip" || -z "$target_port" ]]; then
            log_warn "所有字段都必须填写！"
            continue
        fi
        if ! [[ "$ext_port" =~ ^[1-9][0-9]{0,4}$ && "$ext_port" -le 65535 ]] || \
           ! [[ "$target_port" =~ ^[1-9][0-9]{0,4}$ && "$target_port" -le 65535 ]]; then
            log_warn "端口必须是 1-65535 之间的数字！"
            continue
        fi
        if ! is_valid_ipv4 "$target_ip"; then
            log_warn "目标IP格式错误！"
            continue
        fi

        DNAT_ENTRIES+=("$proto:$ext_port:$target_ip:$target_port")
        log_info "已添加规则: $proto $ext_port -> $target_ip:$target_port"

        safe_read continue_yn "是否继续添加更多端口转发规则？(y/n): "
        if ! is_yes "$continue_yn"; then
            break
        fi
    done
}

# ============================================================
# 规则操作函数
# ============================================================

# 清空现有iptables规则（可选择）
clear_existing_rules() {
    echo ""
    local clear_rules
    safe_read clear_rules "是否清空现有iptables规则？(y/n): "
    if ! is_yes "$clear_rules"; then
        log_info "保留现有规则"
        return
    fi

    # 保存默认策略（用于后续提示）
    local old_input_policy old_forward_policy
    old_input_policy=$(_get_default_policy INPUT)
    old_forward_policy=$(_get_default_policy FORWARD)

    # 备份现有规则（使用固定名称 + 时间戳双份）
    BACKUP_FILE="/root/iptables-backup-pre-nat.rules"
    local ts_backup
    ts_backup="/root/iptables-backup-$(date +%Y%m%d-%H%M%S).rules"

    log_warn "正在备份现有规则..."
    if ! iptables-save > "$BACKUP_FILE" 2>/dev/null; then
        log_error "规则备份失败！操作中止"
        BACKUP_FILE=""
        return 1
    fi
    cp "$BACKUP_FILE" "$ts_backup"
    log_info "规则已备份到: $BACKUP_FILE"
    log_info "时间戳副本:     $ts_backup"

    # 先设置 ACCEPT 默认策略，防止 SSH 锁死
    log_warn "临时设置默认策略为 ACCEPT（防止连接中断）..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    # 清空所有表（包括 mangle 和 raw）
    log_warn "正在清空所有 iptables 规则（filter / nat / mangle / raw）..."
    local table
    for table in filter nat mangle raw; do
        iptables -t "$table" -F 2>/dev/null || true
    done
    for table in filter nat mangle raw; do
        iptables -t "$table" -X 2>/dev/null || true
    done
    log_info "规则已清空"
    log_info "如需恢复原有规则，请执行: iptables-restore < $BACKUP_FILE"
}

# 清理旧的 SNAT 规则（处理 WAN_IP 变化导致规则累积的场景）
_cleanup_stale_snat() {
    local table="$1"
    # 使用进程替换避免管道中的 subshell 导致 break 失效
    while IFS= read -r line_num; do
        [[ -z "$line_num" ]] && break
        iptables -t "$table" -D POSTROUTING "$line_num" 2>/dev/null || break
    done < <(iptables -t "$table" -L POSTROUTING -n --line-numbers 2>/dev/null | \
        awk -v s="$LAN_SUBNET" -v o="$WAN_IF" '$0 ~ s && $0 ~ o {print $1}')
}

# 幂等地添加 iptables 规则
_iptables_add() {
    iptables -C "$@" 2>/dev/null || iptables -A "$@"
}

# 应用iptables规则
apply_iptables_rules() {
    APPLY_STARTED=true
    log_step "正在应用iptables规则..."

    # --- 检测 SSH 端口 ---
    # 优先从 sshd_config 解析（精确）
    local ssh_port
    ssh_port=$(grep -oP '^Port\s+\K\d+' /etc/ssh/sshd_config 2>/dev/null | head -1)
    if [[ -n "$ssh_port" ]]; then
        log_info "从 sshd_config 检测到SSH端口: $ssh_port"
    else
        # 回退：从监听端口过滤 sshd 进程
        ssh_port=$(ss -Htlnp 2>/dev/null | grep -i sshd | awk '{for(i=1;i<=NF;i++) if($i~/:[0-9]+$/){split($i,a,":"); print a[length(a)]; exit}}')
        if [[ -n "$ssh_port" ]]; then
            log_info "从监听端口检测到SSH端口: $ssh_port"
        else
            ssh_port=22
            log_warn "无法检测SSH端口，默认使用 22"
        fi
    fi

    # --- 开启 IP 转发 ---
    ORIGINAL_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    log_info "开启IP转发（原始值: $ORIGINAL_FORWARD）..."
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # --- 基础规则 ---
    # 允许已建立的连接与回环
    _iptables_add INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    _iptables_add FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    _iptables_add INPUT -i lo -j ACCEPT

    # SSH 访问 — 仅限内网接口，防止外网暴露
    _iptables_add INPUT -i "$LAN_IF" -p tcp --dport "$ssh_port" -j ACCEPT

    # --- SNAT 规则 ---
    log_info "应用SNAT规则..."
    _cleanup_stale_snat nat
    if [[ "$SNAT_TYPE" == "SNAT" ]]; then
        _iptables_add -t nat POSTROUTING -s "$LAN_SUBNET" -o "$WAN_IF" -j SNAT --to-source "$WAN_IP"
    else
        _iptables_add -t nat POSTROUTING -s "$LAN_SUBNET" -o "$WAN_IF" -j MASQUERADE
    fi

    # --- FORWARD 规则 ---
    _iptables_add FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT

    # --- DNAT 规则 ---
    if [[ ${#DNAT_ENTRIES[@]} -gt 0 ]]; then
        log_info "应用DNAT规则..."
        local entry proto ext_port target_ip target_port
        for entry in "${DNAT_ENTRIES[@]}"; do
            IFS=':' read -r proto ext_port target_ip target_port <<< "$entry"

            # PREROUTING DNAT 规则
            _iptables_add -t nat PREROUTING -i "$WAN_IF" -p "$proto" --dport "$ext_port" \
                -j DNAT --to-destination "${target_ip}:${target_port}"

            # FORWARD ACCEPT 规则 — -C 检查时不带 comment（避免 nftables 兼容问题）
            if ! iptables -C FORWARD -i "$WAN_IF" -o "$LAN_IF" -p "$proto" \
                -d "$target_ip" --dport "$target_port" \
                -m state --state NEW -j ACCEPT 2>/dev/null; then
                iptables -A FORWARD -i "$WAN_IF" -o "$LAN_IF" -p "$proto" \
                    -d "$target_ip" --dport "$target_port" \
                    -m state --state NEW \
                    -m comment --comment "DNAT:${proto}:${ext_port}->${target_ip}:${target_port}" -j ACCEPT
            fi
        done
    fi

    # --- 验证 SNAT 规则 ---
    log_info "验证规则..."
    # 使用 iptables -C 精确检查（而非 grep 全表 dump）
    if [[ "$SNAT_TYPE" == "SNAT" ]]; then
        if ! iptables -t nat -C POSTROUTING -s "$LAN_SUBNET" -o "$WAN_IF" \
            -j SNAT --to-source "$WAN_IP" 2>/dev/null; then
            log_error "SNAT 规则验证失败！"
            return 1
        fi
    else
        if ! iptables -t nat -C POSTROUTING -s "$LAN_SUBNET" -o "$WAN_IF" \
            -j MASQUERADE 2>/dev/null; then
            log_error "MASQUERADE 规则验证失败！"
            return 1
        fi
    fi
    log_info "规则验证通过"

    RULES_APPLIED=true
    log_info "iptables规则应用完成！"
}

# ============================================================
# 持久化函数
# ============================================================

# 判断是否为 RHEL 系（通过 OS 名称 + ID_LIKE 双重匹配）
_is_rhel_like() {
    case "$OS" in
        centos|rhel|fedora|rocky|almalinux|amzn|ol|oraclelinux) return 0 ;;
        *) [[ "$OS_LIKE" =~ rhel|fedora ]] && return 0 ;;
    esac
    return 1
}

# 保存规则持久化
save_rules() {
    log_step "保存iptables规则..."

    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        # ---- Debian/Ubuntu ----
        if ! command -v netfilter-persistent &>/dev/null; then
            log_warn "iptables-persistent 未安装，正在安装..."
            apt-get update -qq 2>/dev/null || true
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null; then
                log_warn "包安装失败，使用 iptables-save 直接保存"
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                log_info "规则已保存到 /etc/iptables/rules.v4（未安装持久化服务）"
                return
            fi
        fi
        netfilter-persistent save
        log_info "规则已保存（netfilter-persistent）"

    elif _is_rhel_like; then
        # ---- RHEL 系（含 Rocky、Alma、Oracle、Amazon Linux） ----
        local pkg_mgr
        pkg_mgr=$(_pkg_manager)

        # 尝试安装 iptables-services（如果 iptables-save 不可用）
        if ! command -v iptables-save &>/dev/null; then
            if [[ -n "$pkg_mgr" ]]; then
                log_warn "iptables-services 未安装，正在安装..."
                if ! $pkg_mgr install -y iptables-services 2>/dev/null; then
                    log_error "iptables-services 安装失败，请手动安装后重试"
                    exit 1
                fi
            else
                log_error "未找到包管理器，且 iptables-save 不可用。请手动安装 iptables-services"
                exit 1
            fi
        fi

        iptables-save > /etc/sysconfig/iptables
        systemctl enable iptables 2>/dev/null || true
        log_info "规则已保存到 /etc/sysconfig/iptables"

    else
        # ---- 未知系统：使用 iptables-save + systemd oneshot 作为通用方案 ----
        log_warn "未知系统（$OS），使用通用持久化方案"
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4

        # 创建 systemd oneshot 服务（如果 systemd 可用）
        if command -v systemctl &>/dev/null; then
            cat > /etc/systemd/system/iptables-restore.service << 'SYSTEMD_EOF'
[Unit]
Description=Restore iptables rules on boot
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
            systemctl daemon-reload
            systemctl enable iptables-restore.service
            log_info "已创建 systemd 服务: iptables-restore.service"
        else
            log_warn "未检测到 systemd，请确保启动时手动执行: iptables-restore < /etc/iptables/rules.v4"
        fi
    fi
}

# 配置sysctl永久生效（使用 drop-in 文件，兼容 systemd-sysctl）
configure_sysctl() {
    log_step "配置IP转发永久生效..."
    local sysctl_file="/etc/sysctl.d/99-nat-gateway.conf"

    mkdir -p /etc/sysctl.d
    echo "# NAT网关 — IP转发配置（由 install_nat_gateway.sh 生成）" > "$sysctl_file"
    echo "net.ipv4.ip_forward = 1" >> "$sysctl_file"
    log_info "已写入: $sysctl_file"

    # 仅应用目标参数（不使用 sysctl -p 重载全部，避免覆盖运行时调优值）
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    log_info "sysctl配置完成"
}

# ============================================================
# 展示与回滚
# ============================================================

# 显示当前规则
show_rules() {
    log_step "当前的iptables NAT规则："
    echo "=========================================="
    iptables -t nat -L -n -v --line-numbers 2>/dev/null || true
    echo "=========================================="

    log_step "当前的FORWARD规则："
    echo "=========================================="
    iptables -L FORWARD -n -v --line-numbers 2>/dev/null || true
    echo "=========================================="
}

# 生成回滚脚本
generate_rollback_script() {
    log_step "生成回滚脚本..."
    local backup="${BACKUP_FILE:-/root/iptables-backup-pre-nat.rules}"
    local orig_forward="${ORIGINAL_FORWARD:-0}"

    cat > /root/rollback_nat.sh << ROLLBACK_EOF
#!/bin/bash
# ============================================================
# NAT网关配置回滚脚本
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 备份来源: ${backup}
# ============================================================

set -euo pipefail

BACKUP_FILE="${backup}"
ORIGINAL_FORWARD="${orig_forward}"

echo "=========================================="
echo "  NAT网关回滚脚本"
echo "=========================================="

# 从备份恢复 iptables 规则
if [[ -f "\$BACKUP_FILE" ]]; then
    echo "正在从 \$BACKUP_FILE 恢复 iptables 规则..."
    if iptables-restore < "\$BACKUP_FILE" 2>/dev/null; then
        echo "✓ iptables 规则已从备份恢复"
    else
        echo "✗ 规则恢复失败！设置 ACCEPT 默认策略防止锁死..."
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        for table in filter nat mangle raw; do
            iptables -t "\$table" -F 2>/dev/null || true
            iptables -t "\$table" -X 2>/dev/null || true
        done
        echo "警告: 恢复失败，所有规则已清空，默认策略为 ACCEPT"
        exit 1
    fi
else
    echo "警告: 备份文件 \$BACKUP_FILE 不存在"
    echo "正在清空所有规则并设置 ACCEPT 默认策略..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    for table in filter nat mangle raw; do
        iptables -t "\$table" -F 2>/dev/null || true
        iptables -t "\$table" -X 2>/dev/null || true
    done
fi

# 恢复 IP 转发设置
read -r -p "是否关闭IP转发功能？(y/n): " DISABLE_FWD || true
if [[ "\$DISABLE_FWD" =~ ^[Yy]\$ ]]; then
    sysctl -w net.ipv4.ip_forward=0
    rm -f /etc/sysctl.d/99-nat-gateway.conf
    # 同时处理旧版 /etc/sysctl.conf 中的配置
    if grep -q '^#*net\.ipv4\.ip_forward' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^#*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward = 0/' /etc/sysctl.conf
    fi
    echo "IP转发已关闭"
else
    echo "IP转发保持当前状态"
fi
echo ""
echo "回滚完成！"
ROLLBACK_EOF

    chmod +x /root/rollback_nat.sh
    log_info "回滚脚本已生成: /root/rollback_nat.sh"
}

# ============================================================
# 主函数
# ============================================================
main() {
    echo "=========================================="
    echo "    Linux NAT网关配置脚本 v2.0"
    echo "=========================================="
    echo ""

    # ---- 阶段 1: 检查与信息收集 ----
    check_root
    detect_os
    check_dependencies
    check_conflicting_services
    show_interfaces
    get_network_info
    select_snat_mode
    configure_dnat

    # ---- 阶段 2: 配置前确认 ----
    echo ""
    log_step "========================================="
    log_step "  配置确认"
    log_step "========================================="
    echo "  外网接口:     $WAN_IF ($WAN_IP)"
    echo "  内网接口:     $LAN_IF${LAN_IP:+ ($LAN_IP)}"
    echo "  内网网段:     $LAN_SUBNET"
    echo "  SNAT模式:     $SNAT_TYPE"
    echo "  DNAT规则数:   ${#DNAT_ENTRIES[@]} 条"
    echo "========================================="
    local confirm
    safe_read confirm "确认开始配置？(y/n): "
    if ! is_yes "$confirm"; then
        log_info "用户取消操作"
        exit 0
    fi

    # ---- 阶段 3: 执行配置 ----
    clear_existing_rules
    generate_rollback_script    # 先于规则应用，确保即使失败也有回滚工具
    apply_iptables_rules
    configure_sysctl
    save_rules
    show_rules

    # ---- 完成 ----
    echo ""
    log_info "========================================"
    log_info "🎉 NAT网关配置完成！"
    log_info "========================================"
    echo ""
    echo "📋 配置摘要："
    echo "  - 外网接口: $WAN_IF ($WAN_IP)"
    echo "  - 内网接口: $LAN_IF${LAN_IP:+ ($LAN_IP)}"
    echo "  - 内网网段: $LAN_SUBNET"
    echo "  - SNAT模式: $SNAT_TYPE"
    echo "  - DNAT规则: ${#DNAT_ENTRIES[@]} 条"
    echo ""
    echo "🔧 后续操作："
    if [[ -n "${LAN_IP:-}" ]]; then
        echo "  1. 将内网设备的网关设置为 $LAN_IP（内网接口IP）"
    else
        echo "  1. 将内网设备的网关设置为内网接口的IP地址"
    fi
    echo "  2. 测试内网设备是否能访问外网: ping 8.8.8.8"
    echo "  3. 如需回滚: sudo bash /root/rollback_nat.sh"
    if [[ -n "$BACKUP_FILE" ]]; then
        echo "  4. 原始规则备份: $BACKUP_FILE"
    fi
    echo ""
    echo "⚠️  注意：请确保防火墙放行了相应端口！"
    echo "=========================================="
}

# 执行主函数
main
