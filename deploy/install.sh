#!/usr/bin/env bash
# Mynet — 部署脚本（替换配置占位符 + 导入镜像 + 签发证书）
# 用法: ./install.sh [renew-certs]
#
# 前置条件: 已通过 ./config.sh 完成 .env 配置
#
# 行为由 .env 中的以下变量控制:
#   USE_CADDY  (true/false) — 是否使用 Caddy 反向代理
#   CERT_MODE  (auto/manual) — 是否通过 acme.sh 申请证书

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ─── 环境检查 ───
check_prereqs() {
    step "检查依赖..."
    command -v docker      >/dev/null 2>&1 || error "请安装 Docker: https://docs.docker.com/engine/install/"
    docker compose version >/dev/null 2>&1 || error "需要 Docker Compose v2+"
    info "Docker $(docker --version | awk '{print $3}' | tr -d ',') / Compose $(docker compose version --short)"
}

# ─── 准备安装目录 ───
setup_install_dir() {
    step "准备安装目录..."
    local install_dir="${INSTALL_PATH:-/opt/mynet}"

    if [ -d "$install_dir" ] && [ "$(ls -A "$install_dir" 2>/dev/null)" ]; then
        warn "安装目录 $install_dir 已存在且非空"
        read -r -p "  是否覆盖？[y/N] " overwrite
        case "$overwrite" in
            [yY]|[yY][eE][sS]) info "将覆盖现有文件..." ;;
            *) error "已取消安装" ;;
        esac
    fi

    mkdir -p "$install_dir"/{config,certs,volumes}
    info "安装目录: $install_dir"
}

# ─── 复制部署文件到安装目录 ───
copy_deploy_files() {
    local install_dir="${INSTALL_PATH:-/opt/mynet}"
    step "复制部署文件到 $install_dir..."

    # 脚本
    for script in start.sh shutdown.sh lib.sh; do
        cp "${SCRIPT_DIR}/${script}" "$install_dir/"
    done
    chmod +x "$install_dir"/*.sh

    # Docker Compose 文件
    cp "${SCRIPT_DIR}/docker-compose.yml" "$install_dir/"
    cp "${SCRIPT_DIR}/docker-compose.caddy.yml" "$install_dir/"
    cp "${SCRIPT_DIR}/docker-compose.nocaddy.yml" "$install_dir/"

    # .env 配置
    cp "${SCRIPT_DIR}/.env" "$install_dir/"

    # ACL 策略文件（无占位符，直接复制）
    cp "${SCRIPT_DIR}/config/acl.hujson" "$install_dir/config/"

    info "部署文件已复制到 $install_dir"
}

# ─── 替换配置占位符 ───
substitute_configs() {
    step "替换配置文件占位符..."

    # 根据部署模式决定 base_url 协议和 cookie_secure
    local proto="http"
    local cookie_secure="false"
    if [ "${USE_CADDY:-true}" = "true" ] && [ "${CERT_MODE:-auto}" = "auto" ]; then
        proto="https"
        cookie_secure="true"
    fi
    local base_url="${proto}://${DOMAIN}"
    info "base_url: ${base_url}  cookie_secure: ${cookie_secure}"

    local config_dir="${SCRIPT_DIR}/config"
    local target_dir="${INSTALL_PATH:-/opt/mynet}/config"

    for template_file in "$config_dir"/headscale.yaml.template "$config_dir"/headplane.yaml.template "$config_dir"/derp.yaml.template; do
        [ -f "$template_file" ] || continue
        local conf_file="${target_dir}/$(basename "${template_file%.template}")"
        info "写入: $(basename "$conf_file")"
        # 从模板复制（确保每次 install 都使用最新 .env 值重新生成）
        cp "$template_file" "$conf_file"
        sed -i \
            -e "s|__DOMAIN__|${DOMAIN}|g" \
            -e "s|__DERP_DOMAIN__|${DERP_DOMAIN:-${DOMAIN}}|g" \
            -e "s|__BASE_URL__|${base_url}|g" \
            -e "s|__COOKIE_SECURE__|${cookie_secure}|g" \
            -e "s|__DB_TYPE__|${DB_TYPE}|g" \
            -e "s|__MAGIC_DNS_DOMAIN__|${MAGIC_DNS_DOMAIN}|g" \
            -e "s|__COOKIE_SECRET__|${COOKIE_SECRET}|g" \
            -e "s|__HEADSCALE_API_KEY__|${HEADSCALE_API_KEY}|g" \
            -e "s|__DERP_PORT__|${DERP_PORT}|g" \
            -e "s|__STUN_PORT__|${STUN_PORT}|g" \
            "$conf_file"
    done

    info "配置文件已就绪"
}

# ─── Caddyfile 处理 ───
prepare_caddyfile() {
    local config_dir="${SCRIPT_DIR}/config"
    local target_dir="${INSTALL_PATH:-/opt/mynet}/config"
    local template="${config_dir}/Caddyfile.template"
    local caddyfile="${target_dir}/Caddyfile"

    if [ "${USE_CADDY:-true}" != "true" ]; then
        info "未使用 Caddy，跳过 Caddyfile 准备"
        return 0
    fi

    step "准备 Caddyfile..."

    local listen_addr
    if [ "${CERT_MODE:-auto}" = "auto" ]; then
        info "证书模式: auto — Caddy 自动 HTTPS"
        listen_addr="{\$DOMAIN:localhost}"
    else
        info "证书模式: manual — Caddy 仅 HTTP"
        listen_addr="{\$DOMAIN:localhost}:80"
    fi

    # 从模板复制后替换（确保每次 install 都使用最新配置）
    cp "$template" "$caddyfile"
    sed -i "s|__LISTEN__|${listen_addr}|" "$caddyfile"
    info "Caddyfile 已就绪"
}

# ─── 导入 Docker 镜像 ───
import_images() {
    step "导入 Docker 镜像..."
    local images_dir="${SCRIPT_DIR}/images"
    local loaded=0

    for tarfile in "$images_dir"/*.tar; do
        [ -f "$tarfile" ] || continue
        local fname=$(basename "$tarfile" .tar)

        case "$fname" in
            mynet-headscale-v1) local img_name="mynet/headscale:v1" ;;
            mynet-headplane-v1) local img_name="mynet/headplane:v1" ;;
            mynet-derper-v1)    local img_name="mynet/derper:v1" ;;
            *) warn "未知镜像文件: $fname，跳过"; continue ;;
        esac

        if docker image inspect "$img_name" >/dev/null 2>&1; then
            info "镜像已存在: $img_name"
        else
            info "导入: $fname → $img_name"
            docker load < "$tarfile"
            loaded=$((loaded + 1))
        fi
    done

    if [ "$loaded" -gt 0 ]; then
        info "成功导入 $loaded 个镜像"
    fi
}

# ─── 单个域名的自签名证书 ───
_generate_self_signed() {
    local domain="$1"
    local certs_dir="${INSTALL_PATH:-/opt/mynet}/certs"
    local cert_file="${certs_dir}/${domain}.crt"
    local key_file="${certs_dir}/${domain}.key"
    local fullchain_file="${certs_dir}/${domain}.fullchain.pem"

    if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        if [ -n "$expiry" ]; then
            local expiry_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
            local now_ts=$(date +%s)
            local days_left=$(( (expiry_ts - now_ts) / 86400 ))
            if [ "$days_left" -gt 30 ]; then
                info "  自签名证书有效 (${days_left} 天后过期)，跳过 ${domain}"
                return 0
            fi
        fi
    fi

    info "  生成自签名证书: ${domain} (有效期 10 年)..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$key_file" \
        -out "$cert_file" \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain}" \
        2>/dev/null
    cp "$cert_file" "$fullchain_file"
}

# ─── DERP 自签名证书 (CERT_MODE=manual 时使用) ───
generate_self_signed_certs() {
    step "生成 DERP 自签名证书..."
    local derp_domain="${DERP_DOMAIN:-${DOMAIN}}"
    mkdir -p "${INSTALL_PATH:-/opt/mynet}/certs"
    _generate_self_signed "$derp_domain"

    # 如果 DERP 使用独立域名，也为主域名生成证书（Caddy 在不使用 HTTPS 时不需要，但保留以防后续使用）
    if [ "$derp_domain" != "$DOMAIN" ]; then
        _generate_self_signed "$DOMAIN"
    fi
    info "自签名证书已就绪"
}

# ─── TLS 证书 ───

# 检测 80 端口是否可用；如被占用则尝试找到 webroot
_detect_webroot() {
    # 常见 webroot 路径
    local candidates=(
        /var/www/html
        /usr/share/nginx/html
        /srv/http
        /var/www
    )
    for p in "${candidates[@]}"; do
        if [ -d "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# 为单个域名签发证书（acme.sh）
_issue_cert() {
    local domain="$1"
    local certs_dir="${INSTALL_PATH:-/opt/mynet}/certs"
    local acme_sh="$HOME/.acme.sh/acme.sh"
    local cert_file="${certs_dir}/${domain}.crt"

    # 如果证书已存在且有效，跳过
    if [ -f "$cert_file" ]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        if [ -n "$expiry" ]; then
            local expiry_ts=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
            local now_ts=$(date +%s)
            local days_left=$(( (expiry_ts - now_ts) / 86400 ))
            if [ "$days_left" -gt 30 ]; then
                info "  ${domain}: 证书有效 (${days_left} 天后过期)，跳过"
                return 0
            else
                warn "  ${domain}: 证书将在 ${days_left} 天后过期，重新签发..."
            fi
        fi
    fi

    # 检查 acme.sh 内部存储是否已有该域名证书（如已签发过则直接导出，无需重新走 --issue 流程）
    local acme_cert_dir="${HOME}/.acme.sh/${domain}_ecc"
    local acme_cert_dir_rsa="${HOME}/.acme.sh/${domain}"
    if [ -d "$acme_cert_dir" ] || [ -d "$acme_cert_dir_rsa" ]; then
        info "  ${domain}: acme.sh 已有证书，直接导出到 certs/..."
        "$acme_sh" --install-cert -d "$domain" \
            --key-file       "${certs_dir}/${domain}.key" \
            --fullchain-file "${certs_dir}/${domain}.fullchain.pem"
        cp "${certs_dir}/${domain}.fullchain.pem" "$cert_file"
        if [ -f "${certs_dir}/${domain}.key" ]; then
            return 0
        fi
        warn "  ${domain}: 导出失败，尝试重新签发..."
    fi

    info "  签发证书: ${domain}"

    if [ -n "${DNS_API_PROVIDER:-}" ] && [ -n "${DNS_API_CREDENTIALS:-}" ]; then
        export "${DNS_API_CREDENTIALS?}"
        "$acme_sh" --issue \
            --dns "dns_${DNS_API_PROVIDER}" \
            -d "$domain" \
            --key-file       "${certs_dir}/${domain}.key" \
            --fullchain-file "${certs_dir}/${domain}.fullchain.pem"
    else
        # 检测 80 端口是否被占用
        local port80_pid
        port80_pid=$(ss -tlnp 'sport = :80' 2>/dev/null | grep -oP 'pid=\K\d+' | head -1 || true)

        if [ -n "$port80_pid" ]; then
            local port80_name
            port80_name=$(ps -p "$port80_pid" -o comm= 2>/dev/null || echo "unknown")

            # 尝试 webroot 模式
            local webroot
            webroot=$(_detect_webroot)
            if [ -n "$webroot" ]; then
                info "  80 端口被 ${port80_name} 占用，使用 webroot 模式 (${webroot})..."
                "$acme_sh" --issue \
                    -d "$domain" \
                    -w "$webroot" \
                    --key-file       "${certs_dir}/${domain}.key" \
                    --fullchain-file "${certs_dir}/${domain}.fullchain.pem" \
                    --server         letsencrypt
            else
                # 无可用 webroot，尝试临时停止占用进程
                warn "  80 端口被 ${port80_name}(PID:${port80_pid}) 占用，且未找到可用 webroot"
                info "  尝试临时停止 ${port80_name}..."
                systemctl stop "$port80_name" 2>/dev/null || kill -STOP "$port80_pid" 2>/dev/null || true
                sleep 1

                "$acme_sh" --issue \
                    --standalone \
                    -d "$domain" \
                    --key-file       "${certs_dir}/${domain}.key" \
                    --fullchain-file "${certs_dir}/${domain}.fullchain.pem" \
                    --server         letsencrypt

                # 恢复进程
                systemctl start "$port80_name" 2>/dev/null || kill -CONT "$port80_pid" 2>/dev/null || true
            fi
        else
            "$acme_sh" --issue \
                --standalone \
                -d "$domain" \
                --key-file       "${certs_dir}/${domain}.key" \
                --fullchain-file "${certs_dir}/${domain}.fullchain.pem" \
                --server         letsencrypt
        fi
    fi

    if [ ! -f "${certs_dir}/${domain}.fullchain.pem" ]; then
        # acme.sh 可能因"证书已签发过"而跳过了签发，尝试从 acme.sh 内部存储安装已有证书
        info "  ${domain}: 尝试从 acme.sh 内部存储安装已有证书..."
        "$acme_sh" --install-cert -d "$domain" \
            --key-file       "${certs_dir}/${domain}.key" \
            --fullchain-file "${certs_dir}/${domain}.fullchain.pem"
    fi

    if [ ! -f "${certs_dir}/${domain}.fullchain.pem" ]; then
        error "证书签发失败 (${domain})。请检查：\n" \
              "  1. 域名 DNS 是否正确解析到本机\n" \
              "  2. 80 端口是否在安全组/防火墙中开放\n" \
              "  3. 或配置 DNS_API_PROVIDER 使用 DNS-01 质询（推荐）"
    fi

    # 为 DERP 准备 .crt 文件（derper 通过 DERP_HOSTNAME 查找对应证书）
    cp "${certs_dir}/${domain}.fullchain.pem" "$cert_file"
    if [ ! -f "${certs_dir}/${domain}.key" ]; then
        error "证书私钥未找到 (${domain})"
    fi
}

setup_certs() {
    step "检查 TLS 证书..."
    local certs_dir="${INSTALL_PATH:-/opt/mynet}/certs"
    local acme_sh="$HOME/.acme.sh/acme.sh"
    local derp_domain="${DERP_DOMAIN:-${DOMAIN}}"

    mkdir -p "$certs_dir"

    # 安装 acme.sh（如未安装）
    if [ ! -x "$acme_sh" ]; then
        info "安装 acme.sh..."
        curl -s https://get.acme.sh | sh -s email="${ACME_EMAIL:-admin@${DOMAIN}}"
        if [ ! -x "$acme_sh" ]; then
            error "acme.sh 安装失败，请手动安装后重试"
        fi
        "$acme_sh" --set-default-ca --server letsencrypt
    fi
    info "acme.sh: $acme_sh"

    # 使用 DNS-01（推荐）或 HTTP-01
    if [ -n "${DNS_API_PROVIDER:-}" ] && [ -n "${DNS_API_CREDENTIALS:-}" ]; then
        info "使用 DNS-01 质询 (${DNS_API_PROVIDER})..."
    else
        info "使用 HTTP-01 质询 (standalone 模式)..."
        info "确保 80 端口已在防火墙/安全组中开放"
    fi

    # 签发主域名证书（Caddy 使用）
    _issue_cert "$DOMAIN"

    # 签发 DERP 证书（始终执行，与主域名相同时快速跳过）
    _issue_cert "$derp_domain"

    info "TLS 证书签发成功"
}

# ─── 证书决策 ───
handle_certs() {
    if [ "${CERT_MODE:-auto}" = "manual" ]; then
        info "证书模式: manual — 跳过 acme.sh，生成自签名证书供 DERP 使用"
        generate_self_signed_certs
    else
        info "证书模式: auto — 通过 acme.sh 申请 Let's Encrypt 证书"
        setup_certs
    fi
}

# ─── 主入口 ───
case "${1:-}" in
    renew-certs)
        load_config
        local install_dir="${INSTALL_PATH:-/opt/mynet}"
        if [ "${CERT_MODE:-auto}" = "manual" ]; then
            warn "证书模式为 manual，无需续期。"
            info "如需重新生成自签名证书，请删除 ${install_dir}/certs/ 目录后重新运行 ./install.sh"
            exit 0
        fi
        # 确保证书签发到安装目录
        setup_certs
        info "证书已续期，运行 cd ${install_dir} && ./start.sh 重启服务使其生效"
        ;;
    *)
        check_prereqs
        load_config
        setup_install_dir
        copy_deploy_files
        substitute_configs
        prepare_caddyfile
        import_images
        handle_certs
        local install_dir="${INSTALL_PATH:-/opt/mynet}"
        echo ""
        echo -e "${GREEN}══════════════════════════════════════════${NC}"
        echo -e "${GREEN}  部署完成！${NC}"
        echo -e "${GREEN}══════════════════════════════════════════${NC}"
        echo ""
        echo -e "  安装路径:   ${CYAN}${install_dir}${NC}"
        echo -e "  ${YELLOW}下一步: cd ${install_dir} && ./start.sh${NC}"
        if [ "${USE_CADDY:-true}" = "true" ]; then
            echo -e "  Caddy:       ${GREEN}✓ 已启用${NC} (证书: ${CERT_MODE:-auto})"
        else
            echo -e "  Caddy:       ${YELLOW}✗ 未启用${NC} (直连模式)"
        fi
        echo ""
        ;;
esac
