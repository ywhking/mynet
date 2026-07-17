#!/usr/bin/env bats
# ============================================================================
# 容器生命周期测试套件
# TC-CONTAINER-0x: 验证所有 Docker 容器正常启动、运行及健康状态
# ============================================================================

load helpers/common

setup() {
  check_docker
}

# ---------------------------------------------------------------------------
# TC-CONTAINER-01 ~ TC-CONTAINER-03: 容器运行状态
# ---------------------------------------------------------------------------

@test "TC-CONTAINER-01 | headscale 容器处于 running 状态" {
  run container_state headscale
  assert_success
  assert_equal "$output" "running"
}

@test "TC-CONTAINER-02 | headplane 容器处于 running 状态" {
  run container_state headplane
  assert_success
  assert_equal "$output" "running"
}

@test "TC-CONTAINER-03 | derper 容器处于 running 状态" {
  run container_state derper
  assert_success
  assert_equal "$output" "running"
}

# ---------------------------------------------------------------------------
# TC-CONTAINER-04 ~ TC-CONTAINER-05: 容器非重启循环
# ---------------------------------------------------------------------------

@test "TC-CONTAINER-04 | derper 容器未处于 restarting 状态" {
  run container_state derper
  assert_success
  refute_output "restarting"
}

@test "TC-CONTAINER-05 | headscale 容器未处于 restarting 状态" {
  run container_state headscale
  assert_success
  refute_output "restarting"
}

# ---------------------------------------------------------------------------
# TC-CONTAINER-06 ~ TC-CONTAINER-08: 容器健康检查
# ---------------------------------------------------------------------------

@test "TC-CONTAINER-06 | headscale 健康检查状态为 healthy" {
  run container_health headscale
  assert_success
  assert_equal "$output" "healthy"
}

@test "TC-CONTAINER-07 | derper 健康检查状态为 healthy" {
  run container_health derper
  assert_success
  assert_equal "$output" "healthy"
}

@test "TC-CONTAINER-08 | headplane 健康检查状态为 healthy（或无 healthcheck）" {
  run container_health headplane
  assert_success
  # headplane 可能未定义 healthcheck，允许 healthy 或 none
  assert_regex "$output" "^(healthy|none)$"
}

# ---------------------------------------------------------------------------
# TC-CONTAINER-09 ~ TC-CONTAINER-11: 端口暴露
# ---------------------------------------------------------------------------

@test "TC-CONTAINER-09 | headscale 在 0.0.0.0:8080 监听 HTTP API" {
  run container_listening_ports headscale
  assert_success
  assert_output --partial ":8080"
}

@test "TC-CONTAINER-10 | headscale 在 0.0.0.0:9090 监听 Metrics/gRPC" {
  run container_listening_ports headscale
  assert_success
  assert_output --partial ":9090"
}

@test "TC-CONTAINER-11 | derper 在 0.0.0.0:3340 监听 DERP relay" {
  run container_listening_ports derper
  assert_success
  assert_output --partial ":3340"
}

@test "TC-CONTAINER-12 | derper 在 0.0.0.0:3478 监听 STUN (UDP)" {
  run container_listening_ports derper
  assert_success
  assert_output --partial ":3478"
}
