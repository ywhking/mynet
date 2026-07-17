# 系统测试套件 — Docker 服务端到端验证

验证 Headscale + Headplane + DERP 容器化部署的正确性。

## 目录结构

```
tests/system/
├── helpers/
│   └── common.bash        # 公共辅助函数 & 断言 & HTTP/容器工具
├── container.bats          # 容器生命周期测试 (TC-CONTAINER-01 ~ 12)
├── derp.bats               # DERP 服务器功能测试 (TC-DERP-01 ~ 06)
├── integration.bats        # Headscale ↔ DERP 集成测试 (TC-INT-01 ~ 10)
├── run.sh                  # 统一测试运行器
└── README.md
```

## 快速开始

```bash
# 确保服务已启动
cd deploy && docker compose up -d

# 运行全部系统测试
cd ../tests/system && ./run.sh

# 仅运行 DERP 功能测试
./run.sh derp

# 仅运行集成测试
./run.sh integration
```

## 依赖

| 依赖 | 必需 | 说明 |
|------|------|------|
| Docker | ✅ | 所有测试依赖 Docker 运行中 |
| BATS | ❌ 可选 | `apt install bats` 或 `brew install bats-core`；未安装时自动回退到原生 bash 模式 |

## 测试用例清单

### 容器生命周期 (`container.bats`)

| 编号 | 测试名称 | 验证点 |
|------|----------|--------|
| TC-CONTAINER-01 | headscale 容器处于 running 状态 | 容器存活 |
| TC-CONTAINER-02 | headplane 容器处于 running 状态 | 容器存活 |
| TC-CONTAINER-03 | derper 容器处于 running 状态 | 容器存活 |
| TC-CONTAINER-04 | derper 未处于 restarting 状态 | 无重启循环 |
| TC-CONTAINER-05 | headscale 未处于 restarting 状态 | 无重启循环 |
| TC-CONTAINER-06 | headscale 健康检查 healthy | healthcheck 通过 |
| TC-CONTAINER-07 | derper 健康检查 healthy | healthcheck 通过 |
| TC-CONTAINER-08 | headplane 健康检查正常 | healthy 或无 healthcheck |
| TC-CONTAINER-09 | headscale :8080 监听 HTTP API | 端口绑定 |
| TC-CONTAINER-10 | headscale :9090 监听 Metrics/gRPC | 端口绑定 |
| TC-CONTAINER-11 | derper :3340 监听 DERP relay | 端口绑定 |
| TC-CONTAINER-12 | derper :3478 监听 STUN (UDP) | 端口绑定 |

### DERP 功能 (`derp.bats`)

| 编号 | 测试名称 | 验证点 |
|------|----------|--------|
| TC-DERP-01 | HTTP 端口可达 | TCP 连通性 |
| TC-DERP-02 | STUN UDP 端口可达 | UDP 连通性 |
| TC-DERP-03 | GET / 返回 200 | HTTP 服务正常 |
| TC-DERP-04 | GET / 返回有效 HTML | 内容正确 |
| TC-DERP-05 | /derp WebSocket 端点存在 | WS 升级就绪 |
| TC-DERP-06 | 容器内 wget 自检通过 | 与 healthcheck 一致 |

### 集成测试 (`integration.bats`)

| 编号 | 测试名称 | 验证点 |
|------|----------|--------|
| TC-INT-01 | Headscale API 可达 | HTTP 连通 |
| TC-INT-02 | /derp 返回 Region 900 | DERP 配置已加载 |
| TC-INT-03 | DERP Map 包含节点 900a | 节点存在 |
| TC-INT-04 | DERP 端口 3340 已注册 | 端口映射正确 |
| TC-INT-05 | RegionCode = local-derp | 区域代码正确 |
| TC-INT-06 | Headscale 日志无 DERP 错误 | 配置解析正常 |
| TC-INT-07 | Headscale 日志有 DERP 启动信息 | DERP 已处理 |
| TC-INT-08 | Headscale 可解析 derper 容器名 | DNS/网络互通 |
| TC-INT-09 | Headscale /health 端点正常 | 服务健康 |
| TC-INT-10 | 容器间 DERP HTTP 互通 | Compose 网络正常 |

## BATS 模式 vs 原生模式

| 特性 | BATS 模式 | 原生模式 |
|------|-----------|----------|
| 安装 | 需要 `bats` | 零依赖 |
| 输出格式 | TAP 标准格式 | 彩色可读输出 |
| setup/teardown | 完整支持 | setup 支持 |
| 并行执行 | `bats -j 4` | 不支持 |
| 断言丰富度 | assert_output/refute/assert_regex 等 | 基础断言子集 |

建议安装 BATS 获得最佳体验：`sudo apt install bats`
