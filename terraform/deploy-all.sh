#!/usr/bin/env bash
# ============================================================
# deploy-all.sh — Mynet 一键部署脚本
#
# 流程:
#   1. terraform apply          创建云资源（VPC/子网/ECS/安全组/DNS）
#   2. generate_inventory.sh    生成 Ansible 静态 inventory（hosts.yml）
#   3. setup-network.yml        配置 NAT 网关 + 内网外网连通验证
#   4. setup-docker.yml         所有 ECS 安装 Docker
#   5. setup-netbird.yml        堡垒机部署 NetBird 服务端
#   6. setup-netbird-agent.yml  安装 NetBird 客户端并注册 peer
#
# 错误处理: 每一步失败后自动重试（指数退避，默认最多 3 次）；
#   重试全部耗尽 → 立即停止后续步骤，返回非零退出码。
#
# 用法:
#   ./deploy-all.sh                        # 完整部署
#   ./deploy-all.sh --start docker         # 从 docker 步骤开始（跳过前置步骤）
#   ./deploy-all.sh --skip netbird         # 跳过 NetBird 服务端部署
#   ./deploy-all.sh --help
#
# 常用环境变量（均有默认值）:
#   ALICLOUD_ACCESS_KEY / ALICLOUD_SECRET_KEY   阿里云凭证（必需，或 ~/.alibabacloud/credentials）
#   NETBIRD_LETSENCRYPT_EMAIL                    Let's Encrypt 邮箱（默认 admin@ohmynet.vip）
#   NETBIRD_ADMIN_EMAIL / NETBIRD_ADMIN_PASSWORD NetBird 初始 admin 覆盖（默认见 setup-netbird.yml）
#   NETBIRD_PACKAGE / NETBIRD_DOMAIN             NetBird 服务端离线包 / 域名覆盖
#   NETBIRD_BINARY / NETBIRD_MANAGEMENT_URL / NETBIRD_SETUP_EMAIL / NETBIRD_SETUP_PASSWORD / NETBIRD_AGENT_TARGET
#   DOCKER_REPO_BASE / DOCKER_MIRRORS / DOCKER_TARGET
#     中国区加速安装 Docker（download.docker.com 会被 GFW 间歇性 RST）:
#     DOCKER_REPO_BASE=https://mirrors.aliyun.com/docker-ce/linux/ubuntu \
#     DOCKER_MIRRORS=https://docker.m.daocloud.io
#   DEPLOY_RETRY_TIMES   每步最大重试次数（默认 3）
#   DEPLOY_RETRY_DELAY   重试基础等待秒数（默认 15，指数退避，上限 60s）
#   SSH_WAIT_RETRIES     等待 ECS SSH 就绪的尝试次数（默认 15）
#   TF_APPLY_TIMEOUT     terraform apply 超时秒数（默认 1800）
#   PLAYBOOK_TIMEOUT     ansible-playbook 超时秒数（默认 3600）
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
LOG_DIR="$SCRIPT_DIR/logs"

# ---- 颜色（仅终端输出时启用；日志文件不写入 ANSI 码）----
if [[ -t 1 ]]; then COLOR=1; else COLOR=0; fi
C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'; C_RESET=$'\e[0m'

# ---- 参数默认值（可用环境变量覆盖）----
DEPLOY_RETRY_TIMES="${DEPLOY_RETRY_TIMES:-3}"
DEPLOY_RETRY_DELAY="${DEPLOY_RETRY_DELAY:-15}"
SSH_WAIT_RETRIES="${SSH_WAIT_RETRIES:-15}"
TF_APPLY_TIMEOUT="${TF_APPLY_TIMEOUT:-1800}"
PLAYBOOK_TIMEOUT="${PLAYBOOK_TIMEOUT:-3600}"
NETBIRD_LETSENCRYPT_EMAIL="${NETBIRD_LETSENCRYPT_EMAIL:-admin@ohmynet.vip}"

# ---- 日志（所有输出同时写入日志文件）----
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy-all-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()   { if (( COLOR )); then echo -e "${C_CYAN}[$(date '+%H:%M:%S')]${C_RESET} $*"; else echo "[$(date '+%H:%M:%S')] $*"; fi }
warn()  { if (( COLOR )); then echo -e "${C_YELLOW}⚠ $*${C_RESET}"; else echo "⚠ $*"; fi }
error() { if (( COLOR )); then echo -e "${C_RED}✗ $*${C_RESET}" >&2; else echo "✗ $*" >&2; fi }

usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  --start <step>   从指定步骤开始执行（跳过前置步骤）
  --skip <step,...> 跳过指定步骤（逗号分隔）
  -h, --help       显示帮助

步骤（按顺序）:
  terraform  创建云资源 (terraform apply)
  inventory  生成 Ansible inventory (generate_inventory.sh --write)
  ssh_wait   等待 ECS SSH 就绪 (ansible all -m ping)
  network    配置 NAT 网关 + 内网连通 (setup-network.yml)
  docker     安装 Docker 环境 (setup-docker.yml)
  netbird    部署 NetBird 服务端 (setup-netbird.yml)
  agent      安装 NetBird 客户端并注册 (setup-netbird-agent.yml)

示例:
  $0                                  # 完整部署
  $0 --start docker                   # 从 docker 步骤开始
  $0 --skip netbird                   # 跳过 NetBird 服务端部署
  $0 --start terraform --skip ssh_wait
EOF
}

# ---- 前置检查 ----
preflight() {
    local missing=()
    for cmd in terraform ansible-playbook jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if ((${#missing[@]})); then
        error "缺少必需命令: ${missing[*]}（apt-get install ${missing[*]}）"
        exit 1
    fi

    if [[ ! -f "$SCRIPT_DIR/terraform.tfvars" ]]; then
        error "未找到 terraform.tfvars — 请先: cp terraform.tfvars.example terraform.tfvars 并填写"
        exit 1
    fi

    # 阿里云凭证: 环境变量或共享凭证文件至少其一
    if [[ -z "${ALICLOUD_ACCESS_KEY:-}" || -z "${ALICLOUD_SECRET_KEY:-}" ]]; then
        if [[ ! -f "$HOME/.alibabacloud/credentials" ]]; then
            error "未设置 ALICLOUD_ACCESS_KEY / ALICLOUD_SECRET_KEY 环境变量，且不存在 ~/.alibabacloud/credentials"
            exit 1
        fi
    fi

    # 软检查: 离线安装包 / 客户端二进制（默认路径缺失仅警告，可用环境变量覆盖）
    if [[ ! -f "/home/ywhking/develop/netbird-install-20260816.tar.gz" ]]; then
        warn "NetBird 服务端离线包不存在（setup-netbird.yml 默认路径），可用 NETBIRD_PACKAGE 覆盖"
    fi
    if [[ ! -f "/home/ywhking/develop/netbird/netbird" ]]; then
        warn "NetBird 客户端二进制不存在（setup-netbird-agent.yml 默认路径），可用 NETBIRD_BINARY 覆盖"
    fi
}

# ---- 各步骤实现（重试循环调用）----
step_terraform() {
    ( cd "$SCRIPT_DIR" \
        && terraform init -input=false \
        && timeout "$TF_APPLY_TIMEOUT" terraform apply -auto-approve -input=false )
}

step_inventory() {
    # 显式用 bash 执行，避免脚本文件缺失执行位（Windows 拷贝/打包后常见）导致失败
    bash "$SCRIPT_DIR/ansible/inventory/generate_inventory.sh" --write
}

step_ssh_wait() {
    ( cd "$ANSIBLE_DIR" && ansible all -m ping )
}

step_network() {
    ( cd "$ANSIBLE_DIR" && timeout "$PLAYBOOK_TIMEOUT" ansible-playbook playbooks/setup-network.yml )
}

step_docker() {
    local extra=()
    if [[ -n "${DOCKER_REPO_BASE:-}" ]]; then extra+=( -e "docker_repo_base=$DOCKER_REPO_BASE" ); fi
    if [[ -n "${DOCKER_MIRRORS:-}" ]]; then extra+=( -e "docker_mirrors=$DOCKER_MIRRORS" ); fi
    if [[ -n "${DOCKER_TARGET:-}" ]]; then extra+=( -e "docker_target=$DOCKER_TARGET" ); fi
    ( cd "$ANSIBLE_DIR" && timeout "$PLAYBOOK_TIMEOUT" ansible-playbook playbooks/setup-docker.yml "${extra[@]}" )
}

step_netbird() {
    local extra=()
    if [[ -n "${NETBIRD_PACKAGE:-}" ]]; then extra+=( -e "netbird_package=$NETBIRD_PACKAGE" ); fi
    if [[ -n "${NETBIRD_DOMAIN:-}" ]]; then extra+=( -e "netbird_domain=$NETBIRD_DOMAIN" ); fi
    if [[ -n "${NETBIRD_ADMIN_EMAIL:-}" ]]; then extra+=( -e "netbird_admin_email=$NETBIRD_ADMIN_EMAIL" ); fi
    if [[ -n "${NETBIRD_ADMIN_PASSWORD:-}" ]]; then extra+=( -e "netbird_admin_password=$NETBIRD_ADMIN_PASSWORD" ); fi
    ( cd "$ANSIBLE_DIR" && timeout "$PLAYBOOK_TIMEOUT" ansible-playbook playbooks/setup-netbird.yml \
        -e "netbird_letsencrypt_email=$NETBIRD_LETSENCRYPT_EMAIL" "${extra[@]}" )
}

step_agent() {
    local extra=()
    if [[ -n "${NETBIRD_BINARY:-}" ]]; then extra+=( -e "netbird_binary=$NETBIRD_BINARY" ); fi
    if [[ -n "${NETBIRD_MANAGEMENT_URL:-}" ]]; then extra+=( -e "netbird_management_url=$NETBIRD_MANAGEMENT_URL" ); fi
    if [[ -n "${NETBIRD_SETUP_EMAIL:-}" ]]; then extra+=( -e "netbird_setup_email=$NETBIRD_SETUP_EMAIL" ); fi
    if [[ -n "${NETBIRD_SETUP_PASSWORD:-}" ]]; then extra+=( -e "netbird_setup_password=$NETBIRD_SETUP_PASSWORD" ); fi
    if [[ -n "${NETBIRD_AGENT_TARGET:-}" ]]; then extra+=( -e "netbird_agent_target=$NETBIRD_AGENT_TARGET" ); fi
    ( cd "$ANSIBLE_DIR" && timeout "$PLAYBOOK_TIMEOUT" ansible-playbook playbooks/setup-netbird-agent.yml "${extra[@]}" )
}

# ---- 重试封装: 失败指数退避重试，耗尽后返回 1 ----
run_with_retry() {
    local desc="$1" retries="$2" delay_base="$3" fn="$4"
    local attempt=1 delay
    while (( attempt <= retries )); do
        if "$fn"; then
            return 0
        fi
        if (( attempt == retries )); then
            error "[$desc] 重试 $retries 次全部失败"
            return 1
        fi
        delay=$(( delay_base * 2 ** (attempt - 1) ))
        if (( delay > 60 )); then
            delay=60
        fi
        warn "[$desc] 失败（第 $attempt/$retries 次），${delay}s 后重试…"
        sleep "$delay"
        (( attempt++ ))
    done
}

# ---- 单步执行（含步骤级日志与计时）----
run_step() {
    local name="$1" fn desc
    case "$name" in
        terraform) fn=step_terraform ;;
        inventory) fn=step_inventory ;;
        ssh_wait)  fn=step_ssh_wait ;;
        network)   fn=step_network ;;
        docker)    fn=step_docker ;;
        netbird)   fn=step_netbird ;;
        agent)     fn=step_agent ;;
        *) error "未知步骤: $name"; return 1 ;;
    esac
    desc="${STEP_DESC[$name]}"

    log ""
    log "════════════════════════════════════════════════════════"
    log "▶ 步骤 [$name]: $desc"
    log "════════════════════════════════════════════════════════"

    local start_time end_time
    start_time=$(date +%s)
    if run_with_retry "$desc" "${STEP_RETRIES[$name]}" "$DEPLOY_RETRY_DELAY" "$fn"; then
        end_time=$(date +%s)
        log "✅ 步骤 [$name] 完成（耗时 $(( end_time - start_time ))s）"
        return 0
    fi
    return 1
}

# ---- 部署结果汇总 ----
show_summary() {
    log ""
    log "════════════════════ 部署结果 ════════════════════"
    if ( cd "$SCRIPT_DIR" && terraform output ) >/dev/null 2>&1; then
        ( cd "$SCRIPT_DIR" && terraform output )
    else
        warn "terraform output 不可用（state 缺失？）"
    fi
}

# ============================================================
# 主流程
# ============================================================
START_FROM=""
SKIP=""
while (($#)); do
    case "$1" in
        --start) START_FROM="${2:?--start 需要步骤名}"; shift 2 ;;
        --skip)  SKIP="${2:?--skip 需要步骤名列表}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

STEPS_ORDER=(terraform inventory ssh_wait network docker netbird agent)
declare -A STEP_DESC=(
    [terraform]="创建云资源（VPC/子网/ECS/安全组/DNS）"
    [inventory]="生成 Ansible 静态 inventory（hosts.yml）"
    [ssh_wait]="等待 ECS SSH 就绪"
    [network]="配置 NAT 网关 + 内网外网连通验证"
    [docker]="安装 Docker 环境"
    [netbird]="部署 NetBird 服务端（traefik + dashboard + server）"
    [agent]="安装 NetBird 客户端并注册 peer"
)
declare -A STEP_RETRIES=(
    [terraform]=$DEPLOY_RETRY_TIMES
    [inventory]=$DEPLOY_RETRY_TIMES
    [ssh_wait]=$SSH_WAIT_RETRIES
    [network]=$DEPLOY_RETRY_TIMES
    [docker]=$DEPLOY_RETRY_TIMES
    [netbird]=$DEPLOY_RETRY_TIMES
    [agent]=$DEPLOY_RETRY_TIMES
)

# 解析 --start / --skip
start_idx=0
if [[ -n "$START_FROM" ]]; then
    found=false
    for i in "${!STEPS_ORDER[@]}"; do
        if [[ "${STEPS_ORDER[$i]}" == "$START_FROM" ]]; then
            start_idx=$i; found=true; break
        fi
    done
    if [[ "$found" == false ]]; then
        error "未知步骤: $START_FROM（可选: ${STEPS_ORDER[*]}）"
        exit 1
    fi
    log "从步骤 [$START_FROM] 开始执行"
fi

declare -A SKIP_MAP=()
if [[ -n "$SKIP" ]]; then
    IFS=',' read -ra skips <<< "$SKIP"
    for s in "${skips[@]}"; do
        if [[ " ${STEPS_ORDER[*]} " == *" $s "* ]]; then
            SKIP_MAP[$s]=1
        else
            error "未知步骤（--skip）: $s（可选: ${STEPS_ORDER[*]}）"
            exit 1
        fi
    done
fi

# ---- 开始 ----
preflight

log ""
log "======================================================"
log "  Mynet 一键部署"
log "  日志文件: $LOG_FILE"
log "  重试: 每步最多 $DEPLOY_RETRY_TIMES 次（指数退避，基础 ${DEPLOY_RETRY_DELAY}s，上限 60s）"
log "  SSH 等待: $SSH_WAIT_RETRIES 次 | terraform 超时: ${TF_APPLY_TIMEOUT}s | playbook 超时: ${PLAYBOOK_TIMEOUT}s"
log "  NetBird Let's Encrypt 邮箱: $NETBIRD_LETSENCRYPT_EMAIL"
log "======================================================"

for i in "${!STEPS_ORDER[@]}"; do
    if (( i < start_idx )); then
        continue
    fi
    name="${STEPS_ORDER[$i]}"
    if [[ -n "${SKIP_MAP[$name]:-}" ]]; then
        log "跳过步骤: $name（--skip）"
        continue
    fi
    if ! run_step "$name"; then
        error "========== 部署失败，终止于步骤 [$name] =========="
        error "完整日志: $LOG_FILE"
        error "修复问题后可重跑: $0 --start $name"
        exit 1
    fi
done

show_summary
log ""
log "🎉 全部步骤完成！"
log "日志文件: $LOG_FILE"
