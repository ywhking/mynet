#!/usr/bin/env bash
# Mynet — Container image build script
# 用法: ./build.sh [headscale|derper|headplane|all]
#
# 使用子项目自带 Dockerfile 构建镜像，并导出为 deploy/images/*.tar
# 对应关系:
#   headscale → mynet/headscale:v1  (headscale/Dockerfile)
#   derper    → mynet/derper:v1     (tailscale/Dockerfile.derper)
#   headplane → mynet/headplane:v1  (headplane/Dockerfile)
#
# 依赖: docker, git, go (vendor)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
IMAGES_DIR="$ROOT_DIR/deploy/images"

# ─── 颜色 ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}▶ $*${NC}"; }

# ─── 版本号生成 ───
get_version() {
    local module_dir="$1"
    local version
    version=$(git -C "$module_dir" describe --tags --always --dirty 2>/dev/null || echo "dev")
    echo "$version"
}

# ─── 预检 ───
check_prereqs() {
    step "检查构建依赖..."
    command -v docker >/dev/null 2>&1 || error "请安装 Docker"
    info "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

    for sub in headscale headplane tailscale; do
        if [ -f "$ROOT_DIR/$sub/go.mod" ] || [ -f "$ROOT_DIR/$sub/package.json" ] || [ -d "$ROOT_DIR/$sub/cmd" ]; then
            info "子项目 $sub 已就绪"
        else
            error "子项目 $sub 未找到，请先运行: git submodule update --init --recursive"
        fi
    done

    mkdir -p "$IMAGES_DIR"
}

# ═══════════════════════════════════════════════════════════════════
# Headscale 镜像构建 (使用 headscale/Dockerfile)
# ═══════════════════════════════════════════════════════════════════
build_headscale() {
    local version image_tag
    version=$(get_version "$ROOT_DIR/headscale")
    image_tag="mynet/headscale:v1"
    local output_file="$IMAGES_DIR/mynet-headscale-v1.tar"
    local dockerfile="$ROOT_DIR/headscale/Dockerfile"

    step "构建 Headscale 镜像 ($version)"

    if [ ! -f "$dockerfile" ]; then
        error "未找到 Dockerfile: $dockerfile"
    fi

    # headscale/Dockerfile 使用 -mod=vendor，需要 vendor 目录
    if [ ! -d "$ROOT_DIR/headscale/vendor" ]; then
        info "创建 vendor 目录..."
        (cd "$ROOT_DIR/headscale" && go mod vendor)
    fi

    docker build \
        -t "$image_tag" \
        --build-arg VERSION="$version" \
        -f "$dockerfile" \
        "$ROOT_DIR/headscale"

    info "导出 $output_file"
    docker save -o "$output_file" "$image_tag"
    info "Headscale 镜像构建完成 ($output_file)"
}

# ═══════════════════════════════════════════════════════════════════
# Derper 镜像构建 (使用 tailscale/Dockerfile.derper)
# ═══════════════════════════════════════════════════════════════════
build_derper() {
    local version image_tag
    version=$(get_version "$ROOT_DIR/tailscale")
    image_tag="mynet/derper:v1"
    local output_file="$IMAGES_DIR/mynet-derper-v1.tar"
    local dockerfile="$ROOT_DIR/tailscale/Dockerfile.derper"

    step "构建 Derper 镜像 (tailscale $version)"

    if [ ! -f "$dockerfile" ]; then
        error "未找到 Dockerfile: $dockerfile"
    fi

    docker build \
        -t "$image_tag" \
        -f "$dockerfile" \
        "$ROOT_DIR/tailscale"

    info "导出 $output_file"
    docker save -o "$output_file" "$image_tag"
    info "Derper 镜像构建完成 ($output_file)"
}

# ═══════════════════════════════════════════════════════════════════
# Headplane 镜像构建 (使用 headplane 自带的 Dockerfile)
# ═══════════════════════════════════════════════════════════════════
build_headplane() {
    local version image_tag
    version=$(get_version "$ROOT_DIR/headplane")
    image_tag="mynet/headplane:v1"
    local output_file="$IMAGES_DIR/mynet-headplane-v1.tar"
    local dockerfile="$ROOT_DIR/headplane/Dockerfile"

    step "构建 Headplane 镜像 ($version)"

    if [ ! -f "$dockerfile" ]; then
        error "未找到 Dockerfile: $dockerfile"
    fi

    docker build \
        -t "$image_tag" \
        --build-arg HEADPLANE_VERSION="$version" \
        --build-arg IMAGE_TAG="$version" \
        -f "$dockerfile" \
        "$ROOT_DIR/headplane"

    info "导出 $output_file"
    docker save -o "$output_file" "$image_tag"
    info "Headplane 镜像构建完成 ($output_file)"
}

# ═══════════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════════
build_all() {
    build_headscale
    build_derper
    build_headplane
}

print_summary() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  构建完成！${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    echo -e "  镜像输出目录: ${CYAN}${IMAGES_DIR}${NC}"
    echo ""
    ls -lh "$IMAGES_DIR"/*.tar 2>/dev/null || warn "未生成镜像文件"
    echo ""
    echo -e "  ${YELLOW}下一步: 运行 deploy/install.sh 进行部署${NC}"
}

main() {
    check_prereqs

    case "${1:-all}" in
        headscale) build_headscale ;;
        derper)    build_derper ;;
        headplane) build_headplane ;;
        all)       build_all ;;
        *)
            echo "用法: $0 [headscale|derper|headplane|all]"
            echo ""
            echo "  headscale  — 仅构建 Headscale 控制服务器镜像"
            echo "  derper     — 仅构建 DERP 中继服务器镜像"
            echo "  headplane  — 仅构建 Headplane Web 管理界面镜像"
            echo "  all        — 构建全部三个镜像（默认）"
            exit 1
            ;;
    esac

    print_summary
}

main "${1:-all}"
