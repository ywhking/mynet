#!/usr/bin/env bash
# ============================================================================
# 系统测试公共辅助函数
# 路径约定：tests/system/ 相对于项目根目录
# ============================================================================
set -euo pipefail

# --- 项目路径 ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$SYSTEM_DIR/../.." && pwd)"
COMPOSE_FILE="$PROJECT_DIR/deploy/docker-compose.yml"
COMPOSE_CMD="docker compose -f $COMPOSE_FILE"

export SCRIPT_DIR SYSTEM_DIR PROJECT_DIR COMPOSE_FILE COMPOSE_CMD

# --- 颜色输出 ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

pass()  { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; }
skip()  { echo -e "  ${YELLOW}⊘${NC} $* (SKIPPED)"; }
info()  { echo -e "  ${BLUE}ℹ${NC} $*"; }

# --- 测试统计（原生模式） ----------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

increment_run()     { TESTS_RUN=$((TESTS_RUN + 1)); }
increment_passed()  { TESTS_PASSED=$((TESTS_PASSED + 1)); }
increment_failed()  { TESTS_FAILED=$((TESTS_FAILED + 1)); }
increment_skipped() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); }

# --- 预检：确保 docker compose 可用 ------------------------------------------
check_docker() {
  if ! docker info &>/dev/null; then
    echo "ERROR: Docker 未运行或无权限访问。请启动 Docker 后重试。" >&2
    exit 1
  fi
}

# --- 预检：确保所有容器已启动 ------------------------------------------------
require_containers() {
  local missing=()
  for container in headscale headplane derper; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
      missing+=("$container")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: 以下容器未运行: ${missing[*]}" >&2
    echo "       请先执行: cd $PROJECT_DIR/deploy && docker compose up -d" >&2
    return 1
  fi
}

# --- 容器状态查询工具 --------------------------------------------------------
container_state() {
  local name="$1"
  docker ps -a --format '{{.Names}}\t{{.State}}' 2>/dev/null \
    | awk -v n="$name" 'BEGIN {found=0} $1==n {print $2; found=1; exit} END {if (!found) print "missing"}'
}

container_health() {
  local name="$1"
  docker inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null
}

container_listening_ports() {
  local name="$1"
  docker exec "$name" sh -c 'ss -tuln 2>/dev/null || netstat -tuln 2>/dev/null' 2>/dev/null || true
}

# --- HTTP 请求工具 -----------------------------------------------------------
http_get_code() {
  local url="$1"
  curl -sf -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "000"
}

http_get_body() {
  local url="$1"
  curl -sf --connect-timeout 5 --max-time 10 "$url" 2>/dev/null
}

# --- 原生模式断言（BATS 环境下自动跳过，使用 BATS 内置断言）-------------------
if ! command -v bats &>/dev/null && [[ -z "${BATS_VERSION:-}" ]]; then

  # ---- BATS 兼容: run / output / status ---------------------------------
  run() {
    local tmp_out
    tmp_out="$(mktemp)"
    if "$@" >"$tmp_out" 2>&1; then
      status=0
    else
      status=$?
    fi
    output="$(cat "$tmp_out")"
    rm -f "$tmp_out"
    export status output
  }

  run_cmd() { run "$@"; }  # 别名

  # ---- BATS 兼容: assert_success / assert_failure ------------------------
  assert_success() {
    local message="${1:-command expected to succeed}"
    increment_run
    if [[ ${status:-0} -eq 0 ]]; then
      increment_passed
      pass "$message"
    else
      increment_failed
      fail "$message (exit=$status)"
    fi
  }

  assert_failure() {
    local message="${1:-command expected to fail}"
    increment_run
    if [[ ${status:-0} -ne 0 ]]; then
      increment_passed
      pass "$message"
    else
      increment_failed
      fail "$message (expected non-zero exit)"
    fi
  }

  # ---- BATS 兼容: assert_output ------------------------------------------
  assert_output() {
    increment_run
    if [[ "$1" == "--partial" ]]; then
      # assert_output --partial "substring"
      local needle="$2"
      local message="${3:-}"
      if [[ "$output" == *"$needle"* ]]; then
        increment_passed
        pass "${message:+$message — }output contains '$needle'"
      else
        increment_failed
        fail "${message:+$message — }output does not contain '$needle'"
        echo "      actual: ${output:0:200}" >&2
      fi
    elif [[ "$1" == "--regexp" ]]; then
      # assert_output --regexp "pattern"
      local pattern="$2"
      local message="${3:-}"
      if echo "$output" | grep -Eq "$pattern"; then
        increment_passed
        pass "${message:+$message — }output matches /$pattern/"
      else
        increment_failed
        fail "${message:+$message — }output does not match /$pattern/"
        echo "      actual: ${output:0:200}" >&2
      fi
    else
      local expected="$1"
      local message="${2:-}"
      if [[ "$output" == "$expected" ]]; then
        increment_passed
        pass "${message:+$message — }output matches"
      else
        increment_failed
        fail "${message:+$message — }expected '$expected', got '$output'"
      fi
    fi
  }

  # ---- BATS 兼容: refute_output ------------------------------------------
  refute_output() {
    increment_run
    if [[ "$1" == "--partial" ]]; then
      local needle="$2"
      local message="${3:-}"
      if [[ "$output" != *"$needle"* ]]; then
        increment_passed
        pass "${message:+$message — }output does not contain '$needle'"
      else
        increment_failed
        fail "${message:+$message — }output contains forbidden '$needle'"
      fi
    else
      local needle="$1"
      local message="${2:-}"
      if [[ "$output" != "$needle" && "$output" != *"$needle"* ]]; then
        increment_passed
        pass "${message:+$message — }output refuted '$needle'"
      else
        increment_failed
        fail "${message:+$message — }output should not contain '$needle'"
      fi
    fi
  }

  # ---- BATS 兼容: assert_regex (值匹配正则) ------------------------------
  assert_regex() {
    local value="$1"
    local pattern="$2"
    local message="${3:-}"
    increment_run
    if echo "$value" | grep -Eq "$pattern"; then
      increment_passed
      pass "${message:+$message — }'$value' =~ /$pattern/"
    else
      increment_failed
      fail "${message:+$message — }'$value' !~ /$pattern/"
    fi
  }

  # ---- BATS 兼容: skip --------------------------------------------------
  skip() {
    local reason="${1:-test skipped}"
    increment_skipped
    echo "  ${YELLOW}⊘${NC} $reason (SKIPPED)"
    # 退出码特殊处理：调用者应检查 BATS 环境
    if [[ -z "${BATS_VERSION:-}" ]]; then
      exit 0  # 原生模式下直接退出测试函数
    fi
  }

  # ---- 基础断言 ----------------------------------------------------------
  assert() {
    local condition="$1"
    local message="${2:-assertion failed}"
    increment_run
    if eval "$condition"; then
      increment_passed
      pass "$message"
    else
      increment_failed
      fail "$message — 条件: $condition"
    fi
  }

  assert_equal() {
    local got="$1"
    local expected="$2"
    local message="${3:-}"
    increment_run
    if [[ "$got" == "$expected" ]]; then
      increment_passed
      pass "${message:+$message — }got '$expected'"
    else
      increment_failed
      fail "${message:+$message — }expected '$expected', got '$got'"
    fi
  }

  assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-}"
    increment_run
    if [[ "$haystack" == *"$needle"* ]]; then
      increment_passed
      pass "${message:+$message — }contains '$needle'"
    else
      increment_failed
      fail "${message:+$message — }output does not contain '$needle'"
    fi
  }

  assert_empty() {
    local value="$1"
    local message="${2:-}"
    increment_run
    if [[ -z "$value" ]]; then
      increment_passed
      pass "${message:+$message — }is empty"
    else
      increment_failed
      fail "${message:+$message — }expected empty, got '$value'"
    fi
  }

  assert_not_empty() {
    local value="$1"
    local message="${2:-}"
    increment_run
    if [[ -n "$value" ]]; then
      increment_passed
      pass "${message:+$message — }is not empty"
    else
      increment_failed
      fail "${message:+$message — }expected non-empty, got empty"
    fi
  }

  run_cmd() {
    local tmp_out
    tmp_out="$(mktemp)"
    if "$@" >"$tmp_out" 2>&1; then
      status=0
    else
      status=$?
    fi
    output="$(cat "$tmp_out")"
    rm -f "$tmp_out"
    export status output
  }

  print_summary() {
    echo ""
    echo "=========================================="
    echo -n "  结果: "
    if [[ $TESTS_FAILED -eq 0 ]]; then
      echo -e "${GREEN}全部通过${NC}"
    else
      echo -e "${RED}存在失败${NC}"
    fi
    echo "  总计: $TESTS_RUN | 通过: $TESTS_PASSED | 失败: $TESTS_FAILED | 跳过: $TESTS_SKIPPED"
    echo "=========================================="
    return $TESTS_FAILED
  }
fi
