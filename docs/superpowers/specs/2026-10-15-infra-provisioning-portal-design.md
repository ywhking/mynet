# 基础设施自助部署门户 — 设计文档

- **日期**：2026-10-15
- **状态**：已确认（待进入实现计划）
- **项目**：mynet

## 1. 背景与问题

当前 `mynet` 仓库通过「手改 `terraform.tfvars` → `terraform apply` → 跑 ansible playbook」的方式在阿里云上部署基础设施（VPC、public/internal 两个子网、N 台 ECS、堡垒机 NAT、DNS 域名解析、NetBird VPN + Docker 环境）。整个过程依赖运维人员手动编辑配置并执行命令行，无法交给非运维用户自助操作。

本设计目标是构建一个**自托管的 Web 控制台**，让多个租户自助配置并部署属于自己的一套基础设施。

## 2. 目标与非目标

### 目标
- 多租户（<20 个租户）各自登录，通过表单配置基础设施（VM 数量、域名、子网段、网络）。
- 一键部署：自动在阿里云创建 VPC + ECS + 堡垒机 NAT + DNS + NetBird，软件栈固定。
- 平台方统一管理所有租户，按租户隔离资源。
- 部署状态可查看、可重试、可回滚（销毁）。

### 非目标（本期不做）
- 部署任意自定义应用（不提供应用目录 / 任意镜像 / Docker Compose 托管）。软件固定为 NetBird VPN + Docker 环境。
- 多租户自带阿里云账号（BYO 凭据）。本期所有资源部署在平台方统一账号。
- 多云 / 多地域自动编排。
- 水平扩展、大规模（200+ 租户）下的严格配额与调度。
- 计费 / 账单系统。

## 3. 成功标准

1. 租户自助注册并登录。
2. 填写配置表单（VM 数量、域名、子网 CIDR 等），点击部署。
3. 后台自动完成 terraform + ansible 全流程，得到一套隔离、可用（能通过域名 + NetBird 访问）的基础设施。
4. 平台方能查看所有租户的资源和部署状态。
5. 部署失败时能查看完整日志、重试或销毁回滚。

## 4. 关键决策（已与用户对齐）

| 维度 | 决定 |
|---|---|
| 用户 | 多客户/租户 |
| 范围 | 只做基础设施（VM 数量、域名、子网、网络），软件固定为 NetBird VPN + Docker 环境 |
| 云账号 | 平台方统一阿里云账号，按**资源组**做租户隔离 |
| 规模 | 小规模（<20 租户，并发部署极少） |
| 租户产生 | 完全自助注册（无审批） |
| 架构 | 方案 A：自托管单体 Web 应用，直接驱动现有 terraform/ansible，内置简单异步任务 |

## 5. 总体架构

```
┌─────────────────────────────────────────────────────────┐
│  前端 SPA (React + Vite)                                  │
│  登录/注册 · 配置表单(VM数量/域名/子网) · 部署状态+日志 · 资源总览 │
└───────────────┬─────────────────────────────────────────┘
                │ REST (JSON)
┌───────────────▼─────────────────────────────────────────┐
│  后端 API (Python FastAPI)                                │
│  认证 · 配额校验 · 生成 tfvars · 创建部署任务                │
└───────┬─────────────────────────────────────┬───────────┘
        │                                     │
   ┌────▼─────────┐                   ┌──────▼──────────┐
   │ SQLite 数据库  │                   │ Worker 进程      │
   │ users/tenants │◄── 轮询 pending ──│ 消费部署任务      │
   │ deployments  │                   │ shell 出 terraform │
   │ runs / 日志   │                   │ + ansible        │
   └──────────────┘                   └──────┬──────────┘
                                             │
                                    ┌────────▼────────┐
                                    │ 阿里云 (统一账号) │
                                    │ 每租户一资源组    │
                                    └─────────────────┘
```

- **前端**：React SPA（认证、配置表单、部署状态/日志、资源总览四个页面）。
- **后端**：FastAPI + SQLAlchemy，SQLite（<20 租户零运维足够）。
- **Worker**：独立进程，从 `runs` 表取 pending 任务，用 `subprocess` 跑 terraform/ansible，日志逐行写回 DB；用全局信号量限制并发（默认同时最多 2 个部署在跑）。
- **阿里云 AccessKey**：只存在服务端（环境变量/secret），前端永不接触。

> 选型理由：ansible 是 Python 生态，后端要生成 tfvars、解析 terraform/ansible 输出、编排子进程，Python 最顺；SQLite 免运维；React 做表单 + 轮询状态。

## 6. 数据模型

| 表 | 关键字段 | 说明 |
|---|---|---|
| `tenant` | id, name, slug, status, quota_json, created_at | slug 用于资源组名/域名前缀 |
| `user` | id, tenant_id, email(唯一), password_hash, role | 自助注册；一个租户可多个用户 |
| `deployment` | id, tenant_id, config_json(快照), status, created_at | 一次部署的完整配置快照 |
| `run` | id, deployment_id, type(create/destroy), status, error, log_path | 一次执行（worker 消费单元） |

`config_json` 是用户表单的完整快照（VM 数量、每台 VM 的 host_name/public_ip/is_bastion/domain_name、子网 CIDR 等），worker 据此生成 `tfvars`——可追溯、可重试。

## 7. 租户隔离、状态与域名

- **资源组隔离**：每租户 `resource_group_name = "mynet-<slug>"`，复用现有 terraform 的资源组机制。
- **Terraform state 隔离**：每租户一个 workspace（local backend，state 落在 `terraform.tfstate.d/<workspace>/`），避免多租户共用一个 state 文件互相覆盖。worker 执行前 `terraform workspace select/new <slug>`。
- **域名**：平台持有通配域名（如 `*.yourplatform.example.com`），租户选一个子域前缀 → `<prefix>.yourplatform.example.com`；每台实例 A 记录 `<instance>.<prefix>...` 由阿里云 DNS（复用现有 `dns.tf`）自动建。备选（本期不做）：租户自带域名 + 提供 DNS API 凭据。
- **并发**：worker 全局信号量，防止阿里云 API 被打爆。

## 8. 部署流程（生命周期）

### 创建部署（用户点「部署」）

1. 后端校验表单 + 配额（VM 数不超限、子网 CIDR 合法且不重叠）。
2. 生成 `tfvars`，写入 `deployment.config_json` 快照，创建 `run`（status=pending）。
3. Worker 取出 → `terraform workspace select/new <slug>` → `terraform apply -var-file=...`。
4. `generate_inventory.sh --write` 刷新 inventory。
5. 依次跑 ansible：`setup-network.yml`（NAT 网关 + 内网连通）→ `setup-docker.yml` → `setup-netbird.yml`（堡垒机部署 NetBird 服务端）→ `setup-netbird-agent.yml`（注册 peer）。
6. 全部成功 → `run.status=succeeded`；前端轮询到成功，展示访问入口（域名、bastion 公网 IP）。

### 销毁部署（用户点「销毁」）

Worker 跑 `terraform destroy` → 清理 workspace → 标记销毁完成。

### 查看 / 重试

前端实时轮询 `run.status` + 拉日志（复用 `deploy-all.sh` 已有的分步重试逻辑，做成「单步重跑」）。

> 关键点：现有 `deploy-all.sh` 已经把「terraform → inventory → network → docker → netbird → agent」串起来，worker 主要用参数化方式调用它（或直接按步调 playbook），不必重写编排逻辑。

## 9. 认证与安全

- **自助注册**：email + 密码（bcrypt），签发 session（HTTP-only cookie 或 JWT）。注册即建一个 `tenant`（用户成为该租户 admin），后续可邀请同租户成员。
- **配额护栏**（自助 + 平台统一计费的关键）：每租户默认配额——最大 VM 数（如 10）、最大公网 IP 数、**每租户**最多同时 1 个运行中的部署；超限则拒绝或排队。可做成可调。（注意与第 5 节「worker 全局并发上限 2」区分：前者是单租户配额，后者是跨所有租户的全局并发控制。）
- **凭据隔离**：阿里云 AccessKey、DNS 凭据只存在服务端环境变量/secret，前端任何接口都不返回；注册用户无任何云凭据接触面。
- **资源命名**：所有阿里云资源名带 `mynet-<slug>` 前缀，防止租户之间命名冲突、便于对账。

## 10. 错误处理

- **失败状态**：任一步失败 → `run.status=failed` + 完整日志（哪一步、什么错）。前端清晰展示。
- **幂等与重试**：terraform state 保证 apply 可重入；ansible 脚本本身幂等；worker 支持对失败 `run` 重试。
- **回滚**：创建失败时可触发 `terraform destroy` 清理已建资源，避免留下半套资源（用户可选自动/手动）。
- **超时与并发**：每步设超时；并发信号量满了则排队 pending，不直接失败。

## 11. 测试

- **单元**：tfvars 生成逻辑、配额校验、表单→config 映射。
- **集成**：mock terraform/ansible（dry-run/占位脚本）验证 `run` 状态机（pending→running→succeeded/failed→重试/回滚）。
- **E2E**：真实阿里云小规模部署一次（成本高，做成可选的手动验证脚本）。

## 12. 风险

1. **自助注册 + 平台统一计费**：任何注册用户都能消耗平台云资源。缓解：默认配额 + 并发限制 + 资源命名前缀便于对账（见第 9 节）。
2. **控制机单点**：Worker 所在主机故障会影响部署。小规模下可接受；后续可迁移到容器 + 持久化 DB。
3. **terraform state 一致性与并发**：并发部署需靠 workspace 隔离 + 全局信号量，避免 state 竞争。
4. **子进程长任务稳定性**：terraform/ansible 单次可能跑十几分钟，worker 需正确处理超时、日志流、进程退出码。

## 13. 范围外（后续可扩展）

- 应用目录 / 自定义应用部署。
- 租户自带云账号（BYO 凭据）。
- 租户自带域名（BYO DNS）。
- 计费与用量统计。
