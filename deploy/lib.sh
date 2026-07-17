#!/usr/bin/env bash
# Mynet — 共享工具库
# 被 config.sh / install.sh / start.sh / shutdown.sh 引用

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── 颜色输出 ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}▶ $*${NC}"; }

# ─── 加载 .env 配置 ───
load_config() {
    if [ ! -f "${SCRIPT_DIR}/.env" ]; then
        error "未找到 .env 文件，请先运行 ./config.sh 进行配置"
    fi
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
    info "域名: ${DOMAIN}"
}

# ─── 根据配置返回 compose 文件参数 ───
compose_args() {
    local files=("${SCRIPT_DIR}/docker-compose.yml")
    if [ "${USE_CADDY:-true}" = "true" ]; then
        files+=("${SCRIPT_DIR}/docker-compose.caddy.yml")
    else
        files+=("${SCRIPT_DIR}/docker-compose.nocaddy.yml")
    fi
    local args=""
    for f in "${files[@]}"; do
        args="$args -f $f"
    done
    echo "$args"
}

# ─── 运行 docker compose（自动带上正确的文件参数） ───
compose() {
    docker compose $(compose_args) "$@"
}
