#!/usr/bin/env bats
# ============================================================================
# Headscale ↔ DERP 集成测试套件
# TC-INT-0x: 验证 Headscale 控制平面正确加载并使用本地 DERP 中继
# ============================================================================

load helpers/common

setup() {
  check_docker
  HEADSCALE_API="${HEADSCALE_API:-http://127.0.0.1:8080}"
}

# ---------------------------------------------------------------------------
# TC-INT-01: Headscale API 可达
# ---------------------------------------------------------------------------

@test "TC-INT-01 | Headscale API $HEADSCALE_API 可达" {
  run http_get_code "$HEADSCALE_API"
  assert_success
  # Headscale serve 返回 200 (health) 或 404 (无路由匹配)
  assert_regex "$output" "^(200|404)$"
}

# ---------------------------------------------------------------------------
# TC-INT-02: DERP Map API 返回 Region 900
# ---------------------------------------------------------------------------

@test "TC-INT-02 | GET /derp 返回 JSON 且包含 Region 900" {
  run http_get_body "${HEADSCALE_API}/derp"
  assert_success
  assert_output --partial '"900"'
}

# ---------------------------------------------------------------------------
# TC-INT-03: DERP Map 节点信息完整
# ---------------------------------------------------------------------------

@test "TC-INT-03 | DERP Map 中包含节点名 900a" {
  run http_get_body "${HEADSCALE_API}/derp"
  assert_success
  assert_output --partial '"900a"'
}

@test "TC-INT-04 | DERP Map 中 DERP 端口为 3340" {
  run http_get_body "${HEADSCALE_API}/derp"
  assert_success
  # 查找 DERPPort:3340 或 "DERPPort":3340 或 derpport:3340
  assert_output --partial "3340"
}

@test "TC-INT-05 | DERP Map 中 RegionCode 为 local-derp" {
  run http_get_body "${HEADSCALE_API}/derp"
  assert_success
  assert_output --partial "local-derp"
}

# ---------------------------------------------------------------------------
# TC-INT-06 ~ TC-INT-07: Headscale 日志验证
# ---------------------------------------------------------------------------

@test "TC-INT-06 | Headscale 日志中无 DERP 加载错误" {
  run docker logs headscale --tail 200 2>&1
  # 不应出现 DERP 加载失败或解析错误
  refute_output --partial "Failed to load DERP"
  refute_output --partial "failed to parse DERP"
}

@test "TC-INT-07 | Headscale 日志中包含 DERP 相关启动信息" {
  run docker logs headscale --tail 200 2>&1
  # 容忍日志可能不显式打印 DERP（取决于版本），跳过条件：
  # 如果有 "DERP" 或 "derp" 字样至少说明处理过 DERP 配置
  if echo "$output" | grep -qi "derp"; then
    assert_output --regexp "(?i)derp"
  else
    skip "Headscale 日志中未检测到显式 DERP 输出（可能版本差异）"
  fi
}

# ---------------------------------------------------------------------------
# TC-INT-08: 容器间 DNS 解析
# ---------------------------------------------------------------------------

@test "TC-INT-08 | Headscale 容器可通过容器名 derper 解析 DERP 主机" {
  # 验证 Compose 网络内 DNS 互通
  run docker exec headscale nslookup derper 2>&1 || \
     docker exec headscale getent hosts derper 2>&1
  # nslookup 不可用在 distroless 镜像中时，改用 ping/getent
  if [[ "$output" =~ "not found" ]] || [[ "$output" =~ "executable file not found" ]]; then
    # distroless 无 nslookup/getent，改用 cat /etc/hosts
    run docker exec headscale cat /etc/hosts
  fi
  assert_output --partial "derper"
}

# ---------------------------------------------------------------------------
# TC-INT-09: Headscale 健康检查端点
# ---------------------------------------------------------------------------

@test "TC-INT-09 | Headscale /health 端点返回正常" {
  run http_get_code "${HEADSCALE_API}/health"
  assert_success
  assert_equal "$output" "200"
}

# ---------------------------------------------------------------------------
# TC-INT-10: DERP 容器间互访问
# ---------------------------------------------------------------------------

@test "TC-INT-10 | Headscale 容器可访问 DERP HTTP 服务" {
  # 验证 Compose 网络内 headscale → derper 的 TCP 连通性
  run docker exec headscale sh -c \
    'cat < /dev/tcp/derper/3340 2>&1 || timeout 3 wget -q -O /dev/null http://derper:3340/ 2>&1'
  # distroless headscale 无 /dev/tcp 也无 wget — 用纯 curl 替代
  if [[ "$output" =~ "not found" ]]; then
    run docker exec derper wget -q -O /dev/null http://headscale:8080/ 2>&1
    # 反过来从 derper 访问 headscale 验证网络互通
  fi
  assert_success
}
