#!/bin/bash
# ============================================================
# 脚本名称: install_docker.sh
# 功能描述: 在 Ubuntu 24.04 上安装 Docker Engine（官方 apt 源）
#           安装步骤与 Docker 官网文档一致：
#             https://docs.docker.com/engine/install/ubuntu/
#           1. Set up Docker's apt repository（deb822 .sources 格式）
#           2. Install the Docker packages
#           3. Verify with the hello-world image
# 适用系统: Ubuntu 24.04 (noble)
# 使用方法: sudo bash install_docker.sh
#
# 可选环境变量（非交互式调用，如 Ansible 场景）:
#   APT_REPO_BASE    Docker apt 仓库地址，默认官方源。
#                    中国区可设: https://mirrors.aliyun.com/docker-ce/linux/ubuntu
#   DOCKER_MIRRORS   Docker Hub 镜像加速器地址（逗号分隔），写入
#                    /etc/docker/daemon.json 的 registry-mirrors。
#                    例: DOCKER_MIRRORS="https://docker.m.daocloud.io,https://mirror.baidubce.com"
#   DOCKER_VERSION   指定安装版本（如 5:26.1.4-1~ubuntu.24.04~noble），
#                    留空则安装仓库内最新稳定版。
#   RUN_HELLO_WORLD  安装后是否运行 hello-world 镜像验证，默认 1；
#                    设为 0 可跳过（无外网/无镜像加速器时）。
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
APT_REPO_BASE="${APT_REPO_BASE:-https://download.docker.com/linux/ubuntu}"
DOCKER_MIRRORS="${DOCKER_MIRRORS:-}"           # 逗号分隔的镜像加速器地址
DOCKER_VERSION="${DOCKER_VERSION:-}"           # 指定版本时仅安装 docker-ce 系列该版本
KEYRING_PATH="/etc/apt/keyrings/docker.asc"
SOURCES_LIST="/etc/apt/sources.list.d/docker.sources"

# 执行脚本的真实用户（sudo 下取 SUDO_USER，用于加入 docker 组）
RUN_USER="${SUDO_USER:-$(whoami)}"
if [[ "$RUN_USER" == "root" ]]; then
    RUN_USER="$(who am i 2>/dev/null | awk '{print $1}')"
fi

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

# 检测系统 — 仅支持 Ubuntu 24.04
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测操作系统（/etc/os-release 不存在）！"
        exit 1
    fi
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "此脚本仅支持 Ubuntu（当前: $ID）！"
        exit 1
    fi
    if [[ "$VERSION_ID" != "24.04" ]]; then
        log_warn "脚本面向 Ubuntu 24.04，当前版本 $VERSION_ID（$VERSION_CODENAME）。"
        log_warn "若源码仓库中不存在该发行版代号，安装将失败——请改用官方 install 脚本。"
    fi
    log_info "检测到系统: $PRETTY_NAME"
}

# 检查/安装前置依赖
check_prereqs() {
    log_step "检查前置依赖..."
    local -a missing=()
    for cmd in curl gpg apt-get; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "正在安装缺失的命令: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    fi
    log_info "前置依赖已就绪"
}

# ============================================================
# 安装函数
# ============================================================

# 清理可能与 Docker 冲突的旧包（幂等，仅在真正安装前执行）
# 包列表与官网一致:
#   docker.io docker-compose docker-compose-v2 docker-doc docker-buildx
#   podman-docker containerd runc
# 用 dpkg --get-selections 过滤出实际已安装（status=install）的包，
# 未安装的包不会出现在输出中，避免 apt remove 空参报错（set -e 下安全）。
remove_conflicting_packages() {
    log_step "检查冲突的旧包..."
    local -a to_remove=()
    mapfile -t to_remove < <(dpkg --get-selections \
        docker.io docker-compose docker-compose-v2 docker-doc docker-buildx \
        podman-docker containerd runc 2>/dev/null | awk '$2 == "install" {print $1}')

    if [[ ${#to_remove[@]} -gt 0 ]]; then
        log_warn "发现可能冲突的旧包: ${to_remove[*]}，正在卸载..."
        DEBIAN_FRONTEND=noninteractive apt-get remove -y "${to_remove[@]}"
    else
        log_info "未发现冲突包"
    fi
}

# 添加 Docker apt 仓库（幂等，重复执行会覆盖为最新源定义）
# 使用 deb822 格式（.sources），与 Docker 官网 Ubuntu 24.04 安装说明一致
# 官方源不可达时自动回退到阿里云镜像源（中国区 download.docker.com 常被墙）
setup_apt_repo() {
    log_step "配置 Docker apt 仓库..."
    install -m 0755 -d /etc/apt/keyrings

    local repo_base="$APT_REPO_BASE"
    # 下载 GPG key（带重试与超时，避免中国区连接重置导致脚本退出）
    if ! curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 -m 30 \
        "${repo_base}/gpg" -o "$KEYRING_PATH"; then
        if [[ "$repo_base" == "https://download.docker.com/linux/ubuntu" ]]; then
            log_warn "官方源 ${repo_base} 不可达，自动回退到阿里云镜像源..."
            repo_base="https://mirrors.aliyun.com/docker-ce/linux/ubuntu"
            curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 -m 30 \
                "${repo_base}/gpg" -o "$KEYRING_PATH" || {
                log_error "阿里云镜像源也不可达，请检查网络，或手动指定 APT_REPO_BASE"
                return 1
            }
        else
            log_error "无法从 ${repo_base} 下载 GPG key，请检查网络或更换 APT_REPO_BASE"
            return 1
        fi
    fi
    chmod a+r "$KEYRING_PATH"

    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

    cat > "$SOURCES_LIST" <<EOF
Types: deb
URIs: ${repo_base}
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: ${KEYRING_PATH}
EOF
    log_info "已写入源: $SOURCES_LIST"
    log_info "  仓库地址: ${repo_base}"
    log_info "  发行版代号: ${codename} (${arch})"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

# 安装 Docker Engine（幂等 — 已安装则跳过）
install_docker() {
    log_step "安装 Docker Engine..."
    if command -v docker &>/dev/null; then
        log_info "docker 已存在: $(docker --version)"
        log_info "跳过安装（如需更新请先卸载或手动执行 apt-get upgrade）"
        return
    fi

    local -a install_args=()
    if [[ -n "$DOCKER_VERSION" ]]; then
        install_args+=(docker-ce="${DOCKER_VERSION}" docker-ce-cli="${DOCKER_VERSION}")
        # 其余插件包安装最新版
        install_args+=(containerd.io docker-buildx-plugin docker-compose-plugin)
    else
        install_args+=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y "${install_args[@]}"
    log_info "Docker 安装完成"
}

# 配置 Docker Hub 镜像加速器（可选）
configure_registry_mirror() {
    if [[ -z "$DOCKER_MIRRORS" ]]; then
        log_warn "未设置 DOCKER_MIRRORS，跳过镜像加速器配置"
        log_warn "中国区拉取镜像建议设置，例如: DOCKER_MIRRORS='https://docker.m.daocloud.io'"
        return
    fi

    log_step "配置 Docker 镜像加速器..."
    local -a mirrors=()
    local m json=""
    IFS=',' read -ra mirrors <<< "$DOCKER_MIRRORS"
    for m in "${mirrors[@]}"; do
        # 去除首尾空白
        m="${m#"${m%%[![:space:]]*}"}"
        m="${m%"${m##*[![:space:]]}"}"
        [[ -n "$m" ]] || continue
        json="${json:+$json,}\"$m\""
    done
    if [[ -z "$json" ]]; then
        log_warn "DOCKER_MIRRORS 内容无效，跳过"
        return
    fi

    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]]; then
        # 保留已有配置并合并 registry-mirrors（Ubuntu 24.04 自带 python3）
        local backup="/etc/docker/daemon.json.bak.$(date +%Y%m%d-%H%M%S)"
        cp /etc/docker/daemon.json "$backup"
        log_info "已备份原 daemon.json 到 $backup"
        python3 -c '
import json, sys
path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
data["registry-mirrors"] = ['"$json"']
with open(path, "w") as f:
    json.dump(data, f, indent=2)
'
    else
        cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [$json]
}
EOF
    fi
    log_info "镜像加速器已写入: $DOCKER_MIRRORS"
    systemctl restart docker
    log_info "docker 服务已重启以应用配置"
}

# 启动 docker 服务并加入 docker 组
setup_service_and_group() {
    log_step "配置 docker 服务与用户组..."
    systemctl enable docker
    systemctl start docker
    log_info "docker 服务已启用并启动"

    if [[ -n "$RUN_USER" && "$RUN_USER" != "root" ]]; then
        if id "$RUN_USER" &>/dev/null; then
            usermod -aG docker "$RUN_USER"
            log_info "用户 $RUN_USER 已加入 docker 组（重新登录后生效，无需 sudo 即可使用 docker）"
        else
            log_warn "用户 $RUN_USER 不存在，跳过 docker 组配置"
        fi
    fi
}

# 验证安装
verify_install() {
    log_step "验证安装..."
    echo "=========================================="
    docker --version
    docker compose version
    echo "=========================================="
    if systemctl is-active --quiet docker; then
        log_info "✓ docker 服务运行中"
    else
        log_error "✗ docker 服务未运行！请检查: journalctl -u docker -n 50"
        return 1
    fi

    # 官网验证步骤：运行 hello-world 镜像（拉取镜像依赖外网/镜像加速器）
    if [[ "${RUN_HELLO_WORLD:-1}" == "1" ]]; then
        log_step "运行 hello-world 镜像验证..."
        if docker run --rm hello-world >/dev/null 2>&1; then
            log_info "✓ hello-world 运行成功，Docker 安装验证通过"
        else
            log_warn "✗ hello-world 运行失败（多为拉取镜像网络问题，非安装问题）"
            log_warn "  中国区请设置 DOCKER_MIRRORS 后重新执行本脚本，或手动重试: docker run --rm hello-world"
        fi
    else
        log_warn "RUN_HELLO_WORLD=0，已跳过 hello-world 验证"
    fi
}

# ============================================================
# 主函数
# ============================================================
main() {
    echo "=========================================="
    echo "    Docker 安装脚本 (Ubuntu 24.04)"
    echo "=========================================="
    echo ""

    check_root
    detect_os
    check_prereqs
    remove_conflicting_packages
    setup_apt_repo
    install_docker
    configure_registry_mirror
    setup_service_and_group
    verify_install

    echo ""
    log_info "========================================"
    log_info "🎉 Docker 安装完成！"
    log_info "========================================"
    echo ""
    echo "📋 配置摘要："
    echo "  - apt 源:     ${APT_REPO_BASE}"
    echo "  - 镜像加速器: ${DOCKER_MIRRORS:-（未配置）}"
    echo ""
    echo "🔧 后续操作："
    if [[ -n "$RUN_USER" && "$RUN_USER" != "root" ]]; then
        echo "  1. 重新登录（或执行 newgrp docker）使 docker 组权限生效"
        echo "  2. 测试: docker run --rm hello-world"
    else
        echo "  1. 测试: docker run --rm hello-world"
    fi
    echo ""
    echo "⚠️  注意：中国区若无法拉取镜像，请设置 DOCKER_MIRRORS 后重新运行本脚本"
    echo "=========================================="
}

# 执行主函数
main
