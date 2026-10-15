# 基础设施自助部署门户

后端与 Worker 都在仓库自带的 venv（`portal/backend/.venv`）下执行，下面用 `.venv/bin/...`
显式调用该解释器（也可以先 `source .venv/bin/activate`，再直接用 `pip` / `python` / `uvicorn`）。

## 0. 配置：一个 `.env`，两个进程共用

`app.config.Settings` 会自动读取 **`portal/backend/.env`**（`pydantic-settings` 的
`env_file`）。API 服务和 Worker 都从这一个文件读配置——**不要**在某个终端里用
`export` 传凭据：Worker 是另一个进程，它拿不到那个终端的环境变量，
结果是 Worker 里的 `ALICLOUD_ACCESS_KEY` 为空，每次 `terraform apply` 都在无凭据状态下跑。

    cd portal/backend
    .venv/bin/pip install -r requirements.txt
    cp .env.example .env

然后编辑 `portal/backend/.env`，至少填这几项：

| 变量 | 说明 |
|---|---|
| `JWT_SECRET_KEY` | 会话 token 的签名密钥。**必填**：内置默认值 `dev-secret-change-me` 已随源码公开，知道它的人可以为任意邮箱伪造 token，等于拿到所有租户的部署。生成：`python -c "import secrets; print(secrets.token_urlsafe(48))"` |
| `ALICLOUD_ACCESS_KEY` / `ALICLOUD_SECRET_KEY` | 平台的阿里云凭据，`terraform apply` 用 |
| `NETBIRD_LETSENCRYPT_EMAIL` | NetBird 服务端的 ACME 通知邮箱。**必填**，且不能是 `@example` / `@test` / `@invalid` 占位地址（`setup-netbird.yml` 会 assert 拒绝） |
| `PLATFORM_DOMAIN` | 已接入云解析 DNS 的主域名，部署域名 = `<subdomain>.<PLATFORM_DOMAIN>` |
| `NETBIRD_PACKAGE` / `NETBIRD_BINARY` | `setup-netbird.yml` / `setup-netbird-agent.yml` 的离线包与二进制路径。留空则用 playbook 内置默认值，而那个默认值是作者机器上的绝对路径（`/home/ywhking/develop/...`），**换台机器必须显式设置** |
| `DOCKER_REPO_BASE` / `DOCKER_MIRRORS` | 中国区装 Docker 的 apt 源与镜像加速器（`download.docker.com` 会被 GFW 间歇性 RST） |

`JWT_SECRET_KEY` 缺失/为默认值、或 `NETBIRD_LETSENCRYPT_EMAIL` 为空/为占位地址时，
API 与 Worker 都会在**启动时**直接报错退出，而不是等到部署跑到一半才失败
（那时 terraform 已经花掉了钱）。本地开发临时绕过只有一种方式：
`ALLOW_INSECURE_DEV_DEFAULTS=true`——**绝不能**在对外服务的环境里设置它。

## 1. 启动后端（API）

    cd portal/backend
    .venv/bin/uvicorn app.main:app --reload

`uvicorn` 从 `portal/backend/.env` 读取全部配置，无需再 `export` 任何变量。

## 2. 启动 Worker（另开终端）

    cd portal/backend
    .venv/bin/python -c "from app.runner import worker_loop; from app.db import SessionLocal; from app.deployer import RealDeployer; worker_loop(SessionLocal, RealDeployer())"

同样读 `portal/backend/.env`——这正是"凭据只写一次"的原因。启动时它会校验上面的必填配置，
并把上一个进程崩溃时遗留的 `running` run 标记为 `failed`（否则租户既不能重试也不能销毁）。

## 3. 启动前端

    cd portal/frontend
    npm install && npm run dev

vite dev server 默认监听 http://localhost:5173，并把 `/api` 代理到 http://localhost:8000。

## 租户隔离：每个租户一个 terraform 工作目录

`terraform/` 只是**模板来源**。每次运行时，后端会把 `*.tf` 与 `scripts/` 复制到
`TENANTS_DIR`（默认 `terraform/.tenants/<slug>/`），并在该目录里执行 terraform：

- `scripts/generate_key.sh` 写的 `../keys` 因此是**每个租户各自的**——否则两个租户会共用
  同一个 `keys/KEY-bastion`，第二个租户的实例会被第一个租户的私钥授权登录；
- terraform 不会自动加载运维人员自己的 `terraform.tfvars`（`ecs_ssh_public_key` 之类），
  因为工作目录里没有这个文件；
- 不再使用 `terraform workspace`，状态天然按目录隔离，也不会污染运维人员后续手动
  `terraform apply` 的工作区。

`terraform/.tenants/` 已加入 `terraform/.gitignore`，不要提交。

> 已知限制：`terraform/ansible/inventory/generate_inventory.sh` 仍从 `terraform/`
> （而不是租户目录）读取 `terraform.tfstate` 与 `keys/`。单租户部署不受影响，
> 但 inventory 生成不会自动跟随租户目录——需要改 ansible 资产，本分支未做。

## E2E 冒烟测试

前置条件：

- 后端已在 http://localhost:8000 运行（见上，且 `portal/backend/.env` 已配好）
- 前端 vite dev 已在 http://localhost:5173 运行（见上）
- 首次运行需要下载浏览器：`npx playwright install chromium`

运行：

    cd portal/e2e
    npm install
    npx playwright test

该测试会用一个随机邮箱真实注册租户，然后断言落到「部署」看板页。

## 后端测试

    cd portal/backend
    .venv/bin/python -m pytest tests/ -q
