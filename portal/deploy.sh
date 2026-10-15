#!/usr/bin/env bash
# ============================================================
# portal 栈部署脚本
#
#   cd portal && ./deploy.sh
#
# 构建并启动 api + worker 两个容器。公网入口由 `deploy/` 那套 Caddy 提供
# （它占着 80/443），本栈不发布任何公网端口，只是加入它的 mynet 网络。
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

info()  { printf '\033[0;32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }
step()  { printf '\n\033[0;36m==> %s\033[0m\n' "$*"; }

# ---------- 前置检查 ----------
check_prereqs() {
    step "检查前置条件"

    command -v docker >/dev/null 2>&1 || { error "未找到 docker"; exit 1; }
    docker info >/dev/null 2>&1 || { error "docker daemon 未运行或不可访问"; exit 1; }
    docker compose version >/dev/null 2>&1 || { error "未找到 docker compose 插件"; exit 1; }

    # 本栈刻意复用 deploy/ 那套栈已存在的网络，以便对方的 Caddy 能按容器名
    # 反代过来。网络缺失时 compose 只会报 "network mynet ... could not be
    # found"，这里给出可执行的修复建议。
    if ! docker network inspect mynet >/dev/null 2>&1; then
        error "docker 网络 'mynet' 不存在。"
        echo "       本栈设计为挂在 deploy/ 那套 Caddy 后面（它占着 80/443），" >&2
        echo "       因此复用它的 mynet 网络。请先在 deploy/ 里跑起那套栈：" >&2
        echo "           cd ../deploy && ./install.sh && ./start.sh" >&2
        echo "       或者（仅当本机不需要 headscale/headplane 时）手动建网后" >&2
        echo "       自行提供 TLS 入口： docker network create mynet" >&2
        exit 1
    fi
    info "docker / compose / mynet 网络 OK"
}

# ---------- 环境文件 ----------
prepare_env() {
    step "准备 $ENV_FILE"

    if [ ! -f "$ENV_FILE" ]; then
        if [ ! -f "$ENV_EXAMPLE" ]; then
            error "缺少 $ENV_EXAMPLE"
            exit 1
        fi
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        error "已从 .env.example 生成 $ENV_FILE —— 请填写后再运行。"
        echo "       至少要填：JWT_SECRET_KEY、ALICLOUD_ACCESS_KEY、ALICLOUD_SECRET_KEY、" >&2
        echo "                 NETBIRD_LETSENCRYPT_EMAIL、PLATFORM_DOMAIN" >&2
        exit 1
    fi

    # 与 deploy/lib.sh 相同的约定：把 .env 导出成环境变量，供 ${VAR} 替换与检查。
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a

    # 自动补一个 JWT 密钥（deploy/config.sh 对 COOKIE_SECRET 也是这么做的）。
    if [ -z "${JWT_SECRET_KEY:-}" ]; then
        local generated
        generated="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))' 2>/dev/null \
                  || openssl rand -base64 48 | tr -d '\n')"
        printf '\n# 由 deploy.sh 自动生成\nJWT_SECRET_KEY=%s\n' "$generated" >> "$ENV_FILE"
        export JWT_SECRET_KEY="$generated"
        info "已生成 JWT_SECRET_KEY 并写回 $ENV_FILE"
    fi

    local missing=()
    [ -n "${ALICLOUD_ACCESS_KEY:-}" ]            || missing+=("ALICLOUD_ACCESS_KEY")
    [ -n "${ALICLOUD_SECRET_KEY:-}" ]            || missing+=("ALICLOUD_SECRET_KEY")
    [ -n "${NETBIRD_LETSENCRYPT_EMAIL:-}" ]      || missing+=("NETBIRD_LETSENCRYPT_EMAIL")
    [ -n "${PLATFORM_DOMAIN:-}" ]                || missing+=("PLATFORM_DOMAIN")
    if ((${#missing[@]})); then
        error "$ENV_FILE 中以下必填项为空：${missing[*]}"
        exit 1
    fi

    if [[ "${PLATFORM_DOMAIN:-}" == *example.com ]]; then
        # 启动校验不会拦这个值，只会在租户第一次 apply 时以 DNS 失败暴露。
        warn "PLATFORM_DOMAIN 仍是 example.com 占位值——租户的 A 记录会建不出来。"
    fi
    info "环境变量检查通过"
}

# ---------- NetBird 制品 ----------
check_artifacts() {
    step "检查 NetBird 制品"

    local artifact_dir="$SCRIPT_DIR/artifacts"
    mkdir -p "$artifact_dir"

    # 这两个文件是 Ansible copy 的源，在**控制端（worker 容器）**解析。
    # 缺失只会在最后两个 play 才暴露 —— 那时云资源已经建好了。
    local missing=()
    for var in NETBIRD_PACKAGE NETBIRD_BINARY; do
        local host_path="${!var:-}"
        [ -n "$host_path" ] || { missing+=("$var 未设置"); continue; }
        # .env 里写的是容器内路径（/artifacts/...），映射回宿主路径检查
        local rel="${host_path#/artifacts/}"
        [ -f "$artifact_dir/$rel" ] || missing+=("$artifact_dir/$rel（对应 $var）")
    done

    if ((${#missing[@]})); then
        warn "以下 NetBird 制品缺失："
        printf '         %s\n' "${missing[@]}" >&2
        warn "没有它们，部署会走完 terraform apply 之后、在 netbird 步骤失败。"
        warn "请把离线安装包与客户端二进制放进 $artifact_dir 后再继续。"
        read -r -p "        仍要继续？[y/N] " ans
        [[ "${ans:-}" =~ ^[Yy]$ ]] || exit 1
    else
        info "NetBird 制品齐全"
    fi
}

# ---------- 构建并启动 ----------
deploy() {
    step "校验并启动"
    docker compose config -q
    info "compose 配置有效"

    step "构建镜像（首次较慢：terraform + ansible 基础镜像）"
    docker compose build

    step "启动服务"
    docker compose up -d

    step "等待 API 健康"
    local i
    for i in $(seq 1 60); do
        if docker compose exec -T api python -c \
             "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/health',timeout=2).status==200 else 1)" \
             >/dev/null 2>&1; then
            info "API 健康"
            return 0
        fi
        sleep 2
    done

    error "API 在 120 秒内未就绪。查看日志： docker compose logs api"
    exit 1
}

# ---------- 下一步 ----------
next_steps() {
    step "部署完成"
    echo
    echo "  本栈不发布公网端口。请确认两件事："
    echo
    echo "  1) DNS：为 portal 的域名添加 A 记录，指向本机公网 IP。"
    echo "     （terraform 只为其 public_devices 里的实例建记录，不会管这台机器）"
    echo
    echo "  2) 现有 Caddy：在 deploy/ 的站点配置里加入下面这段，然后 reload："
    echo
    echo "         ${PORTAL_DOMAIN:-portal.${PLATFORM_DOMAIN}} {"
    echo "             reverse_proxy portal-api:8000"
    echo "         }"
    echo
    echo "     若 deploy/.env 里设置了 PORTAL_DOMAIN，install.sh 会自动写入这段。"
    echo
    echo "  本地直连调试： curl -s http://127.0.0.1:${API_DEBUG_PORT:-18000}/api/health"
    echo "  查看日志：     docker compose logs -f api worker"
    echo "  停止：         ./shutdown.sh"
    echo
}

check_prereqs
prepare_env
check_artifacts
deploy
next_steps
