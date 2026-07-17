#!/usr/bin/env bash
# ============================================================================
# 系统测试运行器 — Docker 服务端到端验证
#
# 用法:
#   ./run.sh                    # 运行全部测试（自动检测 BATS）
#   ./run.sh container          # 仅运行容器测试
#   ./run.sh derp               # 仅运行 DERP 功能测试
#   ./run.sh integration        # 仅运行集成测试
#   ./run.sh --native           # 强制使用原生 bash 模式
#   ./run.sh --help             # 显示帮助
#
# 依赖:
#   - Docker (运行中)
#   - BATS (可选，自动检测): https://github.com/bats-core/bats-core
#     Ubuntu/Debian: sudo apt install bats
#     macOS:         brew install bats-core
#     ../../shells:   npm install -g bats (via npm)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- 颜色 ------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --- 参数解析 ----------------------------------------------------------------
SUITES=()
FORCE_NATIVE=false

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# //'
      exit 0
      ;;
    --native) FORCE_NATIVE=true ;;
    container|derp|integration) SUITES+=("$arg") ;;
    all) SUITES=() ;;
    *)
      echo "未知参数: $arg"
      echo "用法: $0 [all|container|derp|integration] [--native] [--help]"
      exit 1
      ;;
  esac
done

# 默认全部套件
if [[ ${#SUITES[@]} -eq 0 ]]; then
  SUITES=(container derp integration)
fi

# --- 预检 ------------------------------------------------------------------
check_prereqs() {
  echo -e "${BOLD}=== 系统预检 ===${NC}"

  if ! docker info &>/dev/null; then
    echo -e "  ${RED}✗${NC} Docker 未运行 — 请启动 Docker 后重试"
    exit 1
  fi
  echo -e "  ${GREEN}✓${NC} Docker 可用 ($(docker --version | cut -d' ' -f3 | tr -d ','))"

  local compose_file="$SCRIPT_DIR/../../deploy/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    echo -e "  ${RED}✗${NC} 未找到 $compose_file"
    exit 1
  fi
  echo -e "  ${GREEN}✓${NC} Compose 文件存在"
}

# --- 检查容器是否运行 --------------------------------------------------------
check_containers() {
  echo ""
  echo -e "${BOLD}=== 容器状态 ===${NC}"
  local all_running=true

  for svc in headscale headplane derper; do
    local state
    state=$(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | awk -v n="$svc" '$1==n {print $0}')
    if [[ -n "$state" ]]; then
      echo -e "  ${GREEN}✓${NC} $state"
    else
      echo -e "  ${RED}✗${NC} $svc — 未运行"
      all_running=false
    fi
  done

  if ! $all_running; then
    echo ""
    echo -e "  ${YELLOW}提示: 运行以下命令启动所有服务:${NC}"
    echo -e "    cd $(dirname "$compose_file") && docker compose up -d"
    echo ""
    read -rp "  容器未全部运行，是否继续？（部分测试将失败）[y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 1
  fi
}

# --- BATS 检测 --------------------------------------------------------------
detect_bats() {
  if $FORCE_NATIVE; then
    return 1
  fi
  if command -v bats &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} BATS 已安装: $(bats --version 2>&1 | head -1)"
    return 0
  fi
  echo -e "  ${YELLOW}⊘${NC} BATS 未安装 — 将使用原生 bash 模式"
  echo -e "    安装 BATS 以获得更好的测试报告: sudo apt install bats"
  return 1
}

# =========================================================================
# 原生 bash 测试运行器
# =========================================================================
run_native() {
  local bats_file="$1"
  local suite_name
  suite_name="$(basename "$bats_file" .bats)"

  echo ""
  echo -e "${BOLD}${CYAN}━━━ 套件: $suite_name ━━━${NC}"
  echo ""

  # 预处理 .bats 文件：
  #   1. 移除 load 指令（common.bash 已 source）
  #   2. 转换 @test "name" { → 注册测试名 + 隔离子 shell 函数
  #   3. 执行每个测试

  local tmpfile
  tmpfile="$(mktemp)"

  # 生成一个可 source 的脚本
  awk '
    BEGIN { test_count = 0 }
    /^[[:space:]]*load[[:space:]]/ { next }  # 跳过 load 语句
    /^[[:space:]]*@test[[:space:]]+"/ {
      # 提取测试名称
      match($0, /@test[[:space:]]+"([^"]+)"/, arr)
      name = arr[1]
      test_count++
      printf "_test_names[%d]=\"%s\"\n", test_count, name
      printf "_test_func_%d() {\n", test_count
      next
    }
    { print }
  ' "$bats_file" > "$tmpfile"

  # Source 预处理后的测试文件和公共函数
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/helpers/common.bash"
  check_docker

  declare -a _test_names=()
  # shellcheck disable=SC1090
  source "$tmpfile"
  rm -f "$tmpfile"

  local total=0 passed=0 failed=0

  local setup_body=""
  if declare -f setup >/dev/null 2>&1; then
    setup_body="setup"
  fi

  for i in $(seq 1 ${#_test_names[@]}); do
    local name="${_test_names[$i]}"
    total=$((total + 1))

    # 带超时保护的子 shell 中运行
    local test_output
    if test_output=$(timeout 30 bash -c "
      set -euo pipefail
      source '$SCRIPT_DIR/helpers/common.bash'
      $setup_body
      _test_func_$i
    " 2>&1); then
      echo -e "  ${GREEN}✓${NC} $name"
      passed=$((passed + 1))
    else
      local exit_code=$?
      echo -e "  ${RED}✗${NC} $name (exit=$exit_code)"
      if [[ -n "$test_output" ]]; then
        echo "$test_output" | sed 's/^/      /'
      fi
      failed=$((failed + 1))
    fi
  done

  # 汇总
  echo ""
  echo -e "  ${CYAN}套件结果:${NC} $total 项 | ${GREEN}$passed 通过${NC} | ${RED}$failed 失败${NC}"
  return $failed
}

# =========================================================================
# BATS 模式
# =========================================================================
run_bats() {
  local bats_files=()
  for suite in "${SUITES[@]}"; do
    bats_files+=("$SCRIPT_DIR/${suite}.bats")
  done

  echo ""
  # BATS 使用 TAP 格式输出，由 BATS 自行管理格式
  bats --print-output-on-failure --show-output-of-passing-tests "${bats_files[@]}"
}

# =========================================================================
# 主流程
# =========================================================================
main() {
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║  Docker 服务系统测试套件           ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════╝${NC}"
  echo ""

  check_prereqs

  if detect_bats && ! $FORCE_NATIVE; then
    echo ""
    run_bats
  else
    local overall_failed=0
    for suite in "${SUITES[@]}"; do
      local file="$SCRIPT_DIR/${suite}.bats"
      if [[ ! -f "$file" ]]; then
        echo -e "  ${RED}✗${NC} 测试文件不存在: $file"
        overall_failed=$((overall_failed + 1))
        continue
      fi
      run_native "$file" || overall_failed=$((overall_failed + 1))
    done

    echo ""
    echo -e "${BOLD}==========================================${NC}"
    if [[ $overall_failed -eq 0 ]]; then
      echo -e "  ${GREEN}${BOLD}全部套件通过 ✓${NC}"
    else
      echo -e "  ${RED}${BOLD}$overall_failed 个套件存在失败 ✗${NC}"
    fi
    echo -e "${BOLD}==========================================${NC}"
    exit $overall_failed
  fi
}

main
