#!/usr/bin/env bash
# Mynet — 交互式配置脚本
# 用法: ./config.sh
#
# 通过问答方式配置 .env 文件，不修改任何服务配置文件。
# 运行 install.sh 时会将 .env 中的值写入各服务的 YAML 配置。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        Mynet — 交互式配置               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ─── 环境检查 ───
check_environment() {
    step "检查运行环境..."
    local missing=0

    # 必需工具（config.sh 自身需要）
    echo ""
    info "检查必需工具..."
    for cmd in openssl grep sed cut tr head cat; do
        if command -v "$cmd" >/dev/null 2>&1; then
            info "  ✓ ${cmd}"
        else
            error "  ✗ ${cmd} — 未安装，请先安装后重试"
            missing=$((missing + 1))
        fi
    done

    # 可选但推荐的工具（后续 install.sh / start.sh 需要）
    echo ""
    info "检查部署依赖 (后续步骤需要)..."

    if command -v docker >/dev/null 2>&1; then
        info "  ✓ docker ($(docker --version | awk '{print $3}' | tr -d ','))"
    else
        warn "  ✗ docker — 未安装。部署和启动服务需要 Docker"
        warn "    安装指南: https://docs.docker.com/engine/install/"
        missing=$((missing + 1))
    fi

    if docker compose version >/dev/null 2>&1; then
        info "  ✓ docker compose ($(docker compose version --short))"
    else
        warn "  ✗ docker compose — 未安装。需要 Docker Compose v2+"
        missing=$((missing + 1))
    fi

    if command -v curl >/dev/null 2>&1; then
        info "  ✓ curl"
    else
        warn "  ✗ curl — 未安装。签发 TLS 证书时需要"
        missing=$((missing + 1))
    fi

    if [ "$missing" -gt 0 ]; then
        echo ""
        warn "共 ${missing} 项检查未通过"
        if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
            info "核心依赖已满足，可以继续配置（部署前请安装缺失的工具）"
        else
            warn "缺少 Docker，建议先安装后再继续配置"
            read -r -p "  是否仍要继续？[y/N] " proceed
            case "$proceed" in
                [yY]|[yY][eE][sS]) info "继续配置..." ;;
                *) info "已取消，请安装依赖后重试"; exit 0 ;;
            esac
        fi
    else
        echo ""
        info "环境检查全部通过"
    fi
}

check_environment

# ─── 检查是否已配置 ───
if [ -f .env ] && grep -q "^DOMAIN=" .env 2>/dev/null; then
    current_domain=$(grep "^DOMAIN=" .env | head -1 | cut -d= -f2)
    if [ -n "$current_domain" ] && [ "$current_domain" != "vpn.example.com" ]; then
        warn "检测到已有配置 (域名: ${current_domain})"
        read -r -p "  是否重新配置？[y/N] " reconf
        case "$reconf" in
            [yY]|[yY][eE][sS]) info "重新配置..." ;;
            *) info "保留现有配置，退出"; exit 0 ;;
        esac
    fi
fi

echo "  按回车使用方括号中的默认值"
echo ""

# ─── DOMAIN ───
while true; do
    read -r -p "  域名 (如 vpn.example.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        warn "  域名不能为空，请输入类似 vpn.example.com 的完整域名"
        continue
    fi
    if [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        break
    fi
    warn "  域名格式无效，请输入类似 vpn.example.com 的完整域名"
done

# ─── COOKIE_SECRET ───
default_secret=$(openssl rand -hex 16 2>/dev/null || cat /dev/urandom 2>/dev/null | tr -dc 'a-f0-9' | head -c 32)
while true; do
    read -r -p "  Cookie 密钥 (回车自动生成 32 字符随机值): " COOKIE_SECRET
    if [ -z "$COOKIE_SECRET" ]; then
        COOKIE_SECRET="$default_secret"
        info "  已生成随机 Cookie 密钥"
        break
    fi
    if [ "${#COOKIE_SECRET}" -ge 32 ]; then
        break
    fi
    warn "  Cookie 密钥长度不足，需要至少 32 个字符 (当前: ${#COOKIE_SECRET})"
done

# ─── HEADSCALE_API_KEY ───
read -r -p "  Headscale API 密钥 (首次部署可留空): " HEADSCALE_API_KEY

# ─── DERP_DOMAIN ───
echo ""
info "DERP 中继服务器设置"
echo "  DERP 用于在节点间无法直连时中继流量。建议使用独立域名"
echo "  以区别于控制面板（如 derp.vpn.example.com），留空则复用主域名。"
read -r -p "  DERP 域名 [${DOMAIN}]: " DERP_DOMAIN
DERP_DOMAIN="${DERP_DOMAIN:-${DOMAIN}}"

# ─── DERP_PORT ───
while true; do
    read -r -p "  DERP 端口 [3340]: " DERP_PORT
    DERP_PORT="${DERP_PORT:-3340}"
    if [[ "$DERP_PORT" =~ ^[0-9]+$ ]] && [ "$DERP_PORT" -ge 1 ] && [ "$DERP_PORT" -le 65535 ]; then
        break
    fi
    warn "  端口号必须在 1-65535 之间"
done

# ─── STUN_PORT ───
while true; do
    read -r -p "  STUN 端口 [3478]: " STUN_PORT
    STUN_PORT="${STUN_PORT:-3478}"
    if [[ "$STUN_PORT" =~ ^[0-9]+$ ]] && [ "$STUN_PORT" -ge 1 ] && [ "$STUN_PORT" -le 65535 ]; then
        break
    fi
    warn "  端口号必须在 1-65535 之间"
done

# ─── DB_TYPE ───
while true; do
    read -r -p "  数据库类型 (sqlite3/postgres) [sqlite3]: " DB_TYPE
    DB_TYPE="${DB_TYPE:-sqlite3}"
    case "$DB_TYPE" in
        sqlite3|postgres) break ;;
        *) warn "  请输入 sqlite3 或 postgres" ;;
    esac
done

# ─── MAGIC_DNS_DOMAIN ───
while true; do
    read -r -p "  MagicDNS 域名 [vpn]: " MAGIC_DNS_DOMAIN
    MAGIC_DNS_DOMAIN="${MAGIC_DNS_DOMAIN:-vpn}"
    if [[ "$MAGIC_DNS_DOMAIN" =~ ^[a-zA-Z]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        break
    fi
    warn "  MagicDNS 域名格式无效，请输入有效域名（如 vpn、mynet.local）"
done

# ─── 反向代理 ───
echo ""
info "反向代理设置"
echo "  true  — 使用 Caddy 作为反向代理（默认，推荐）"
echo "  false — 不使用 Caddy，直接暴露 Headscale 和 Headplane 端口"
while true; do
    read -r -p "  使用 Caddy 反向代理 (true/false) [true]: " USE_CADDY
    USE_CADDY="${USE_CADDY:-true}"
    case "$USE_CADDY" in
        true|false) break ;;
        *) warn "  请输入 true 或 false" ;;
    esac
done

# ─── 证书模式 (仅在使用 Caddy 时询问) ───
if [ "$USE_CADDY" = "true" ]; then
    echo ""
    info "TLS 证书设置"
    echo "  auto   — 自动通过 Let's Encrypt (acme.sh) 申请证书（默认，推荐）"
    echo "  manual — 不申请证书，Caddy 使用 HTTP，DERP 使用自签名证书"
    while true; do
        read -r -p "  证书模式 (auto/manual) [auto]: " CERT_MODE
        CERT_MODE="${CERT_MODE:-auto}"
        case "$CERT_MODE" in
            auto|manual) break ;;
            *) warn "  请输入 auto 或 manual" ;;
        esac
    done

    if [ "$CERT_MODE" = "manual" ]; then
        warn "已选择不申请证书模式：将不会运行 acme.sh，服务使用 HTTP（无 TLS）"
    fi
else
    CERT_MODE="manual"
    info "未使用 Caddy，跳过证书申请"
fi

# ─── ACME_EMAIL (仅在使用 Caddy 且 auto 证书模式时需要) ───
if [ "$USE_CADDY" = "true" ] && [ "$CERT_MODE" = "auto" ]; then
    while true; do
        read -r -p "  ACME 邮箱 (用于 Let's Encrypt 通知): " ACME_EMAIL
        if [[ "$ACME_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        fi
        warn "  邮箱格式无效，请输入类似 admin@example.com 的有效邮箱"
    done
else
    ACME_EMAIL=""
fi

# ─── DNS API (可选 — 仅在使用 Caddy 且 auto 证书模式时询问) ───
if [ "$USE_CADDY" = "true" ] && [ "$CERT_MODE" = "auto" ]; then
    echo ""
    info "DNS API 用于 Let's Encrypt DNS-01 质询（需要 80 端口时不需配置）"
    echo "  支持: cf (Cloudflare), ali (Aliyun), dgon (DNSPod), he (Hurricane Electric)"
    read -r -p "  DNS API 提供商 (留空跳过): " DNS_API_PROVIDER
    if [ -n "$DNS_API_PROVIDER" ]; then
        read -r -p "  DNS API 凭证环境变量名 (如 CF_Token): " DNS_API_CREDENTIALS
    fi
else
    DNS_API_PROVIDER=""
    DNS_API_CREDENTIALS=""
fi

# ─── INSTALL_PATH ───
echo ""
info "安装路径设置"
echo "  指定服务文件的安装目录。配置、证书、数据卷都将存放在此路径下。"
while true; do
    read -r -p "  安装路径 [/opt/mynet]: " INSTALL_PATH
    INSTALL_PATH="${INSTALL_PATH:-/opt/mynet}"
    if [[ "$INSTALL_PATH" =~ ^/ ]]; then
        break
    fi
    warn "  请输入绝对路径（以 / 开头）"
done

# ─── 写入 .env ───
echo ""
step "写入 .env 文件..."

cat > .env <<EOF
# Mynet 部署配置 — 由 ./config.sh 生成
# 修改后重新运行 ./install.sh 即可生效
DOMAIN=${DOMAIN}
USE_CADDY=${USE_CADDY}
CERT_MODE=${CERT_MODE}
COOKIE_SECRET=${COOKIE_SECRET}
HEADSCALE_API_KEY=${HEADSCALE_API_KEY}
DERP_DOMAIN=${DERP_DOMAIN}
DERP_PORT=${DERP_PORT}
STUN_PORT=${STUN_PORT}
DB_TYPE=${DB_TYPE}
MAGIC_DNS_DOMAIN=${MAGIC_DNS_DOMAIN}
ACME_EMAIL=${ACME_EMAIL:-}
DNS_API_PROVIDER=${DNS_API_PROVIDER:-}
DNS_API_CREDENTIALS=${DNS_API_CREDENTIALS:-}
INSTALL_PATH=${INSTALL_PATH}
EOF

info ".env 文件已生成"

# ─── 显示摘要 ───
echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  配置完成！${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
echo -e "  域名:         ${CYAN}${DOMAIN}${NC}"
echo -e "  DERP 域名:    ${CYAN}${DERP_DOMAIN}${NC}"
echo -e "  Caddy 代理:   ${CYAN}${USE_CADDY}${NC}"
echo -e "  证书模式:     ${CYAN}${CERT_MODE}${NC}"
echo -e "  数据库:       ${CYAN}${DB_TYPE}${NC}"
echo -e "  MagicDNS:     ${CYAN}${MAGIC_DNS_DOMAIN}${NC}"
echo -e "  DERP 端口:    ${CYAN}${DERP_PORT}${NC}"
echo -e "  STUN 端口:    ${CYAN}${STUN_PORT}${NC}"
echo -e "  安装路径:     ${CYAN}${INSTALL_PATH}${NC}"
echo ""
echo -e "  ${YELLOW}下一步: 运行 ./install.sh 进行部署${NC}"
echo ""
