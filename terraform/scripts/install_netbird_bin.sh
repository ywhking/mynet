#!/bin/bash
# ============================================================
# 脚本名称: install_netbird_bin.sh
# 功能描述: 基于自构建的 netbird 二进制安装 NetBird 客户端（agent）
#           完全离线：不访问官方仓库（pkgs.netbird.io / GitHub Releases），
#           二进制由外部预先上传到目标机器后执行本脚本。
#           仅安装 CLI（netbird），不安装 netbird-ui（无桌面环境）。
# 适用系统: Ubuntu 24.04（systemd）
# 使用方法: sudo bash install_netbird_bin.sh
#
# 必填环境变量:
#   NETBIRD_MANAGEMENT_URL   NetBird 管理服务器地址（如 https://bastion.ohmynet.vip）
#
# 可选环境变量:
#   NETBIRD_BIN_SRC                预上传的 netbird 二进制路径，默认 /root/netbird
#   NETBIRD_DISABLE_GEOLOCATION    是否禁用地理定位数据库下载（MaxMind，
#                                  中国区 ECS 访问挂起导致 daemon 卡死），
#                                  默认 1 = 禁用
#
# 幂等性: 重复执行安全 —— 二进制一致且服务运行中时跳过安装。
# 更新客户端: 重新上传新二进制后重跑本脚本（自动替换并重启服务）。
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
# 全局变量（可由环境变量覆盖）
# ============================================================
NETBIRD_MANAGEMENT_URL="${NETBIRD_MANAGEMENT_URL:-}"
NETBIRD_BIN_SRC="${NETBIRD_BIN_SRC:-/root/netbird}"
NETBIRD_DISABLE_GEOLOCATION="${NETBIRD_DISABLE_GEOLOCATION:-1}"
NETBIRD_BIN="/usr/bin/netbird"
CONFIG_DIR="/etc/netbird"
CONFIG_FILE="$CONFIG_DIR/config.json"
DROPIN_DIR="/etc/systemd/system/netbird.service.d"
DROPIN_FILE="$DROPIN_DIR/10-agent-env.conf"

# ============================================================
# 预检查函数
# ============================================================

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 权限运行！"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

# 检测系统（netbird 为静态 Go 二进制，仅提示不强制）
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_warn "无法检测操作系统（/etc/os-release 不存在），继续..."
        return
    fi
    . /etc/os-release
    log_info "检测到系统: $PRETTY_NAME"
    if [[ "$ID" == "ubuntu" && "$VERSION_ID" != "24.04" ]]; then
        log_warn "脚本面向 Ubuntu 24.04，当前 $VERSION_ID —— 请确认 systemd 环境"
    fi
}

# 校验环境变量与预上传二进制
validate_args() {
    if [[ -z "$NETBIRD_MANAGEMENT_URL" ]]; then
        log_error "缺少必填环境变量 NETBIRD_MANAGEMENT_URL（如 https://bastion.ohmynet.vip）"
        exit 1
    fi
    if [[ "$NETBIRD_MANAGEMENT_URL" != https://* ]]; then
        log_error "NETBIRD_MANAGEMENT_URL 必须以 https:// 开头: $NETBIRD_MANAGEMENT_URL"
        exit 1
    fi
    if [[ ! -f "$NETBIRD_BIN_SRC" ]]; then
        log_error "未找到预上传的二进制: $NETBIRD_BIN_SRC"
        echo "  请先上传二进制到目标机，或用 NETBIRD_BIN_SRC 指定路径"
        exit 1
    fi
    # 上传可能丢执行位，这里兜底补上
    if [[ ! -x "$NETBIRD_BIN_SRC" ]]; then
        chmod +x "$NETBIRD_BIN_SRC"
    fi

    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ;;
        *) log_warn "未识别的架构 $(uname -m)（应为 amd64/arm64）" ;;
    esac

    log_info "管理服务器: $NETBIRD_MANAGEMENT_URL"
    log_info "二进制来源: $NETBIRD_BIN_SRC"
}

# ============================================================
# 安装函数
# ============================================================

# 幂等判断: 二进制内容一致 && 服务运行中 → 跳过安装
is_up_to_date() {
    [[ -f "$NETBIRD_BIN" ]] \
        && cmp -s "$NETBIRD_BIN" "$NETBIRD_BIN_SRC" \
        && systemctl is-active --quiet netbird 2>/dev/null
}

install_binary() {
    log_step "安装二进制到 $NETBIRD_BIN ..."
    install -m 0755 "$NETBIRD_BIN_SRC" "$NETBIRD_BIN"
    log_info "已安装: $NETBIRD_BIN ($("$NETBIRD_BIN" version 2>/dev/null | head -n1))"
}

# 写入客户端配置（ManagementURL 预置，netbird up 时无需再指定 --management-url）
# 注意: 自建 dev 版客户端 Config.ManagementURL 为 Go url.URL 结构体
# （client/internal/profilemanager/config.go），JSON 必须写结构体形式；
# 写成字符串会让 daemon 启动即 FATL:
#   json: cannot unmarshal string into Go struct field Config.ManagementURL of type url.URL
# 另: daemon 实际读取的是 profile 文件 /var/lib/netbird/default.json
# （首次启动时从 legacy /etc/netbird/config.json 快照拷贝，之后不再读 legacy），
# 因此两个路径必须都写。如客户端结构变更导致格式再变，可改用
# netbird up --management-url <URL> 让客户端自写配置。
write_config() {
    log_step "写入客户端配置..."
    install -m 0755 -d "$CONFIG_DIR"
    install -m 0755 -d /var/lib/netbird

    # 从 URL 拆出 scheme/host（含端口，如有），与 url.URL 序列化格式一致
    local scheme rest host tmp
    scheme="${NETBIRD_MANAGEMENT_URL%%://*}"
    rest="${NETBIRD_MANAGEMENT_URL#*://}"
    host="${rest%%/*}"
    # 关键: 客户端管理连接的自建 dialer 直接拿 URL Host 做 net.Dial，
    # 不会自动补默认端口 —— 无显式端口时 daemon 每次拨号都报
    #   dial tcp: address <host>: missing port in address
    # （grpc 退避重试 ~30s 后 context 过期 → "dial context: deadline exceeded"，
    #   netbird up 永远无法注册）。这里强制补 :443。
    if [[ "$host" != *:* ]]; then
        host="$host:443"
        log_info "管理服务器 URL 无显式端口，已补 :443 -> $host"
    fi

    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
{
  "ManagementURL": {
    "Scheme": "$scheme",
    "Host": "$host"
  }
}
EOF
    local target mode
    for target in "$CONFIG_FILE" /var/lib/netbird/default.json; do
        # legacy 路径 0644（与旧行为一致）；profile 文件 0600（与客户端自建一致）
        mode=0644
        [[ "$target" = /var/lib/netbird/default.json ]] && mode=0600
        if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
            log_info "配置无变化: $target"
        else
            install -m "$mode" "$tmp" "$target"
            log_info "已写入: $target"
        fi
    done
    rm -f "$tmp"
}

# systemd drop-in: 禁用地理定位数据库下载（中国区 MaxMind 访问挂起）
write_dropin() {
    log_step "配置服务环境变量..."
    install -m 0755 -d "$DROPIN_DIR"

    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# 中国区 ECS 禁用地理定位数据库下载（MaxMind 访问挂起导致 daemon 卡死）
[Service]
Environment=NB_DISABLE_GEOLOCATION=$NETBIRD_DISABLE_GEOLOCATION
EOF
    if [[ -f "$DROPIN_FILE" ]] && cmp -s "$tmp" "$DROPIN_FILE"; then
        rm -f "$tmp"
        log_info "环境变量无变化: $DROPIN_FILE"
    else
        install -m 0644 "$tmp" "$DROPIN_FILE"
        rm -f "$tmp"
        systemctl daemon-reload
        log_info "已写入: $DROPIN_FILE（已 daemon-reload）"
    fi
}

install_service() {
    log_step "注册并启动 netbird 服务..."
    if [[ -f /etc/systemd/system/netbird.service ]]; then
        log_info "服务单元已存在，跳过 netbird service install"
    else
        if ! "$NETBIRD_BIN" service install 2>&1; then
            log_warn "netbird service install 返回非零（可能已注册），继续..."
        fi
        systemctl daemon-reload
        log_info "服务单元已注册"
    fi

    systemctl enable netbird >/dev/null 2>&1 || true
    # 更新二进制时也重启生效；服务未启动时 restart 等价于 start
    systemctl restart netbird
    log_info "netbird 服务已启动"
}

verify_install() {
    log_step "验证安装..."
    echo "=========================================="
    "$NETBIRD_BIN" version
    echo "=========================================="
    if systemctl is-active --quiet netbird; then
        log_info "✓ netbird 服务运行中"
    else
        log_error "✗ netbird 服务未运行！请检查: journalctl -u netbird -n 50"
        return 1
    fi
}

# ============================================================
# 主函数
# ============================================================
main() {
    echo "=========================================="
    echo "    NetBird 客户端安装脚本（自建二进制）"
    echo "=========================================="
    echo ""

    check_root
    detect_os
    validate_args

    if is_up_to_date; then
        log_info "跳过安装：二进制一致且服务运行中"
        echo "SKIP_INSTALL"
        return 0
    fi

    install_binary
    write_config
    write_dropin
    install_service
    verify_install

    echo ""
    log_info "========================================"
    log_info "🎉 NetBird 客户端安装完成！"
    log_info "========================================"
    echo ""
    echo "📋 配置摘要："
    echo "  - 二进制:     $NETBIRD_BIN"
    echo "  - 管理服务器: $NETBIRD_MANAGEMENT_URL"
    echo "  - 地理定位:   $([ "$NETBIRD_DISABLE_GEOLOCATION" = "1" ] && echo '已禁用（中国区）' || echo '启用')"
    echo ""
    echo "🔧 后续操作（注册登录，在目标机执行）："
    echo "  netbird up"
    echo "  （管理服务器地址已写入 $CONFIG_FILE，无需再指定 --management-url）"
    echo ""
    echo "⚠️  更新客户端：替换本地二进制后重跑本脚本即可（自动替换并重启服务）"
    echo "=========================================="
}

# 执行主函数
main
