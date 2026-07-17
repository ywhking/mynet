# Mynet — 一键部署

自托管 Tailscale 兼容 VPN 的全栈部署方案，包含控制服务器 (Headscale)、Web 管理界面 (Headplane)、DERP 中继服务器。

## 架构

```
┌─────────────────────────────────────────────────────┐
│                    公网                              │
│   :80/:443 (HTTP/HTTPS)      :3340 (DERP TLS)       │
│        │                      │                     │
│   ┌────▼────┐           ┌────▼────┐                 │
│   │  Caddy   │           │  DERP   │                 │
│   │ (可选)    │          │ (中继)   │                 │
│   └────┬────┘           └─────────┘                 │
│        │                                            │
│   ┌────▼────┐  ┌──────────┐                         │
│   │Headplane│  │Headscale │   ← 内部网络 mynet      │
│   │ (Web UI)│  │(控制API) │                         │
│   └─────────┘  └──────────┘                         │
└─────────────────────────────────────────────────────┘
```

## 快速开始

### 1. 前置条件

- **域名**：一个指向服务器公网 IP 的域名（如 `vpn.example.com`）
- **端口**：80/TCP、443/TCP、3340/TCP、3478/UDP 开放
- **系统**：Linux (amd64)，安装 Docker 24+ 和 Docker Compose v2
- **OpenSSL**：用于证书验证

```bash
# 安装 Docker（如未安装）
curl -fsSL https://get.docker.com | sh
```

### 2. 配置

```bash
cd deploy/

# 交互式配置（推荐）
./config.sh
```

`config.sh` 会询问以下配置项：

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| `DOMAIN` | 指向服务器 IP 的域名 | 必填 |
| `USE_CADDY` | 是否使用 Caddy 反向代理 | `true` |
| `CERT_MODE` | 证书模式 (`auto`/`manual`) | `auto` |
| `ACME_EMAIL` | Let's Encrypt 通知邮箱 | `auto` 模式时必填 |
| `COOKIE_SECRET` | 32 字符随机密钥 | 自动生成 |
| `DB_TYPE` | 数据库类型 (`sqlite3`/`postgres`) | `sqlite3` |

### 3. 部署模式

#### 模式 A：Caddy 代理 + 自动证书（默认）

```env
USE_CADDY=true
CERT_MODE=auto
```

- Caddy 作为反向代理，自动通过 Let's Encrypt 申请证书
- 对外暴露 80 和 443 端口
- 适合公网生产环境

#### 模式 B：Caddy 代理 + 无证书（HTTP）

```env
USE_CADDY=true
CERT_MODE=manual
```

- Caddy 作为反向代理，使用 HTTP（无 TLS）
- 仅对外暴露 80 端口
- `install.sh` 不会运行 acme.sh，DERP 使用自签名证书
- 适合内网或测试环境

#### 模式 C：直连模式（无 Caddy）

```env
USE_CADDY=false
```

- 不使用 Caddy，Headscale 和 Headplane 直接暴露端口
- Headscale: `http://<DOMAIN>:8080`
- Headplane: `http://<DOMAIN>:3000`
- 证书自动设置为 `manual`（无需公网证书）
- 适合不需要反向代理的简单部署

### 4. 部署

```bash
./install.sh
```

脚本会自动完成：
1. 检查依赖环境
2. 生成配置文件（含 Caddyfile）
3. 导入 Docker 镜像 (`deploy/images/*.tar`)
4. 签发 TLS 证书（`CERT_MODE=auto` 时）或生成自签名证书（`CERT_MODE=manual` 时）
5. 提示运行 `./start.sh` 启动服务

### 5. 启动服务

```bash
./start.sh
```

### 6. 创建用户

```bash
docker exec mynet-headscale /ko-app/headscale users create alice
```

### 7. 客户端连接

```bash
# Caddy + HTTPS 模式
tailscale up --login-server=https://vpn.example.com

# Caddy + HTTP 模式
tailscale up --login-server=http://vpn.example.com

# 直连模式
tailscale up --login-server=http://vpn.example.com:8080
```

浏览器打开对应地址进入 Headplane 管理界面。

## 常用命令

```bash
./start.sh                 # 启动所有服务
./shutdown.sh              # 停止所有服务
./install.sh renew-certs    # 手动续期证书（仅 CERT_MODE=auto）
```

## 管理命令

```bash
# 用户管理
docker exec mynet-headscale /ko-app/headscale users list
docker exec mynet-headscale /ko-app/headscale users create <name>

# 节点管理
docker exec mynet-headscale /ko-app/headscale nodes list
docker exec mynet-headscale /ko-app/headscale nodes list --user <name>

# 预授权密钥（无需手动审批注册）
docker exec mynet-headscale /ko-app/headscale preauthkeys create --user <name>

# API 密钥（供 Headplane 集成使用）
docker exec mynet-headscale /ko-app/headscale apikeys create
```

## 文件结构

```
deploy/
├── .env                       # 实际配置（不提交版本管理）
├── .env.example               # 配置模板
├── config.sh                  # 交互式配置脚本
├── install.sh                  # 部署脚本
├── start.sh                   # 启动脚本
├── shutdown.sh                # 停止脚本
├── lib.sh                     # 共享工具库
├── docker-compose.yml         # 基础服务编排
├── docker-compose.caddy.yml   # Caddy 反向代理叠加
├── docker-compose.nocaddy.yml # 直连模式叠加
├── config/
│   ├── Caddyfile              # Caddy HTTPS 模板
│   ├── Caddyfile.http         # Caddy HTTP 模板
│   ├── Caddyfile.active       # 部署时生成的活跃 Caddyfile
│   ├── headscale.yaml         # Headscale 配置
│   ├── headplane.yaml         # Headplane 配置
│   ├── derp.yaml              # DERP 地图
│   └── acl.hujson             # ACL 访问控制策略
├── images/                    # Docker 镜像 tar 包
│   ├── mynet-headscale-v1.tar
│   ├── mynet-headplane-v1.tar
│   └── mynet-derper-v1.tar
├── certs/                     # TLS 证书（自动生成）
└── volumes/                   # 持久化数据
```

## 证书续期

Let's Encrypt 证书有效期为 90 天。`install.sh` 初次运行时已安装 `acme.sh`，它会自动设置 cron 任务进行续期。

手动续期：

```bash
./install.sh renew-certs
```

> `CERT_MODE=manual` 时无需续期。如需重新生成自签名证书，删除 `certs/` 目录后重新运行 `./install.sh`。

## 安全建议

1. **更换所有默认密钥** — 部署前生成随机 `COOKIE_SECRET`
2. **配置 OIDC** — 在 `.env` 中设置 OIDC 参数，启用 SSO 登录
3. **编辑 ACL** — 根据需求修改 `config/acl.hujson`，限制节点间访问
4. **防火墙** — 仅开放必要端口（Caddy 模式: 80+443；直连模式: 8080+3000；DERP: 3340+3478）
5. **定期备份** — 备份 `./volumes/headscale/` 下的数据库和私钥

## 升级

```bash
# 1. 放入新镜像 tar 包
cp mynet-*.tar deploy/images/

# 2. 重新运行部署
./install.sh

# 3. 重启服务
./start.sh
```

> 脚本会自动导入新镜像并重新创建容器。

## 故障排查

| 症状 | 检查 |
|------|------|
| 客户端连不上 | DNS 解析是否正确；`dig $DOMAIN` |
| DERP 报 TLS 错误 | 证书是否正确签发；`openssl s_client -connect $DOMAIN:3340` |
| 节点离线 | `docker compose logs headscale \| grep -i error` |
| 80 端口冲突 | 关闭占用 80 端口的服务后重试 `./install.sh` |
