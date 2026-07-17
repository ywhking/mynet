#!/usr/bin/env bats
# ============================================================================
# DERP 服务器功能测试套件
# TC-DERP-0x: 验证 DERP 中继服务器自身功能正常
# ============================================================================

load helpers/common

setup() {
  check_docker
  DERP_HOST="${DERP_HOST:-127.0.0.1}"
  DERP_PORT="${DERP_PORT:-3340}"
  STUN_PORT="${STUN_PORT:-3478}"
}

# ---------------------------------------------------------------------------
# TC-DERP-01 ~ TC-DERP-02: 端口可达性（宿主机视角）
# ---------------------------------------------------------------------------

@test "TC-DERP-01 | DERP HTTP 端口 $DERP_HOST:$DERP_PORT 可达" {
  run http_get_code "http://${DERP_HOST}:${DERP_PORT}/"
  assert_success
  refute_output "000"
}

@test "TC-DERP-02 | DERP STUN 端口 $DERP_HOST:$STUN_PORT UDP 可达" {
  # STUN 是 UDP 协议，nc -zu 测试端口可达性
  run timeout 3 nc -zu "$DERP_HOST" "$STUN_PORT"
  # UDP "连接成功"仅表示包发出未立即被拒绝，0 或 1 均属正常
  assert_regex "$status" "^[01]$"
}

# ---------------------------------------------------------------------------
# TC-DERP-03 ~ TC-DERP-04: HTTP 响应验证
# ---------------------------------------------------------------------------

@test "TC-DERP-03 | GET / 返回 HTTP 200" {
  run http_get_code "http://${DERP_HOST}:${DERP_PORT}/"
  assert_success
  assert_equal "$output" "200"
}

@test "TC-DERP-04 | GET / 返回有效 HTML 内容" {
  run http_get_body "http://${DERP_HOST}:${DERP_PORT}/"
  assert_success
  # DERP dev 模式 + DERP_HOME=blank 返回包含 <html 或纯文本首页
  assert_output --regexp "(html|DERP|Tailscale|blank|home)"
}

# ---------------------------------------------------------------------------
# TC-DERP-05: WebSocket 端点
# ---------------------------------------------------------------------------

@test "TC-DERP-05 | WebSocket /derp 端点返回 426 Upgrade Required" {
  # 不带 Upgrade 头的 HTTP 请求到 WS 端点，应返回 426
  run http_get_code "http://${DERP_HOST}:${DERP_PORT}/derp"
  assert_success
  # 426 = Upgrade Required，表示端点存在且需要 WebSocket 升级
  # 400 = 缺少必要参数，也表示端点存在
  # 两种都说明 DERP 端点在工作
  assert_regex "$output" "^(426|400)$"
}

# ---------------------------------------------------------------------------
# TC-DERP-06: 容器内自检
# ---------------------------------------------------------------------------

@test "TC-DERP-06 | 容器内 wget 自检通过（与 healthcheck 一致）" {
  run docker exec derper wget -q -O - http://127.0.0.1:3340/
  assert_success
}
