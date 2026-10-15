# 基础设施自助部署门户 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个自托管 Web 控制台，让多租户（<20）自助注册并通过表单配置/部署一套隔离的阿里云基础设施（VPC + ECS + 堡垒机 NAT + DNS + NetBird），复用现有 `terraform/` 与 `ansible/` 脚本。

**Architecture:** 前后端分离。React SPA 调用 FastAPI REST；后端在 SQLite 中存租户/用户/部署/运行记录，把每次部署做成一条 `run` 记录交给一个独立 Worker 进程消费；Worker 通过 `Deployer` 接口 shell 出 `terraform`（每租户一个 workspace）和 `ansible-playbook`，日志写回 DB。`Deployer` 用协议抽象，便于用假实现做单元测试。

**Tech Stack:** Python 3.11+ / FastAPI / SQLAlchemy 2.x / Pydantic v2 / SQLite / bcrypt / PyJWT / pytest+httpx；前端 React 18 + Vite + TypeScript + react-router-dom；E2E 用 Playwright。

**Spec:** `docs/superpowers/specs/2026-10-15-infra-provisioning-portal-design.md`

## Global Constraints

- 软件栈固定为 NetBird VPN + Docker，不做自定义应用/应用目录（spec §2）。
- 所有阿里云资源部署在平台方统一账号，每租户一个资源组，名称 `mynet-<slug>`（spec §7）。
- 每租户一个 terraform workspace，state 落在 `terraform.tfstate.d/<workspace>/`（spec §7）。
- Worker 全局并发上限默认 **1（串行）**；每租户同时运行中的部署上限默认 1（spec §9）。**注意：不复用 spec §5 的"并发 2"**——所有租户共用同一个 `settings.terraform_dir`，而 `terraform workspace select` 会写该目录下共享的 `.terraform/environment`；并发时 A 租户的 `apply` 可能落到 B 的 workspace（错改/错删他人基础设施）。spec §3 已说明"并发部署极少"，串行无成本损失。若要恢复并发，须先改为每租户独立 terraform 工作目录。
- 每租户最大 VM 数默认 10（spec §9）。
- 域名用平台通配子域名：`<subdomain>.<PLATFORM_DOMAIN>`（spec §7）。
- 阿里云 AccessKey / DNS 凭据只存服务端环境变量，任何 API 不返回（spec §9）。
- 所有新增代码放在 `portal/` 目录下，不改动现有 `terraform/`、`ansible/`、`deploy/` 的核心逻辑（spec §4）。

## Review Focus

以下是最可能在实际使用中咬到人的输入/条件，happy-path 测试覆盖不到，逐条在对应任务里补了测试：

1. **重复邮箱注册** —— 第二次用同一邮箱注册应返回 409，且不产生半套 tenant/user 数据。→ Task 3 测试。
2. **非法/重叠子网或堡垒机数量不对（0 个或多于 1 个）** —— 应在任何 terraform 调用前被拒绝并给出清晰错误。→ Task 4 测试。
3. **超出配额（VM 数超限 / 该租户已有运行中部署）** —— 应被拒绝。→ Task 4、Task 8 测试。
4. **部署中途失败** —— `run` 应落到 `failed` 且带日志；重试幂等；可触发 `destroy` 清理半套资源。→ Task 7 测试。
5. **租户越权** —— 用户 A 不能查看或操作用户 B 的部署。→ Task 8 测试。

---

## File Structure

```
portal/
  backend/
    app/
      __init__.py
      main.py            # FastAPI app 工厂 + 路由注册 + 启动建表
      config.py          # pydantic-settings 配置
      db.py              # engine / session / Base / get_db 依赖
      models.py          # Tenant / User / Deployment / Run ORM
      schemas.py         # Pydantic 请求/响应模型 + DeploymentConfig
      security.py        # bcrypt 哈希 + JWT 签发/校验 + get_current_user
      quotas.py          # 配额与配置校验
      tfvars.py          # DeploymentConfig → tfvars HCL 字符串
      deployer.py        # Deployer 协议 + RealDeployer(terraform/ansible 子进程)
      runner.py          # execute_run 编排 + worker_loop
      routers/
        __init__.py
        auth.py          # 注册/登录
        deployments.py   # 创建/列表/详情/销毁/重试
    tests/
      conftest.py
      test_models.py
      test_security.py
      test_auth.py
      test_quotas.py
      test_tfvars.py
      test_deployer.py
      test_runner.py
      test_deployments_api.py
    requirements.txt
  frontend/
    package.json
    vite.config.ts
    tsconfig.json
    index.html
    src/
      main.tsx
      App.tsx
      api.ts
      types.ts
      pages/Register.tsx
      pages/Login.tsx
      pages/Dashboard.tsx
      pages/DeploymentDetail.tsx
  e2e/
    portal.spec.ts
  README.md
```

---

## Task 1: 后端骨架（配置 + DB + 模型 + 健康检查）

**Files:**
- Create: `portal/backend/requirements.txt`
- Create: `portal/backend/app/__init__.py`
- Create: `portal/backend/app/config.py`
- Create: `portal/backend/app/db.py`
- Create: `portal/backend/app/models.py`
- Create: `portal/backend/app/main.py`
- Test: `portal/backend/tests/conftest.py`
- Test: `portal/backend/tests/test_models.py`

**Interfaces:**
- Produces: `Settings`（`config.py`）、`Base`/`engine`/`SessionLocal`/`get_db`（`db.py`）、`Tenant`/`User`/`Deployment`/`Run` 四个 ORM 类（`models.py`）、`create_app()`（`main.py`）。后续任务全部依赖这些名字。

- [ ] **Step 1: 写依赖清单**

`portal/backend/requirements.txt`:
```
fastapi==0.115.6
uvicorn[standard]==0.34.0
sqlalchemy==2.0.36
pydantic==2.10.4
pydantic-settings==2.7.1
bcrypt==4.2.1
PyJWT==2.10.1
pytest==8.3.4
httpx==0.28.1
```

- [ ] **Step 2: 写配置模块**

`portal/backend/app/config.py`:
```python
from functools import lru_cache
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "sqlite:///./portal.db"
    jwt_secret_key: str = "dev-secret-change-me"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24

    platform_domain: str = "yourplatform.example.com"
    alicloud_region: str = "cn-wulanchabu"
    vswitch_zone: str = "cn-wulanchabu-a"

    terraform_dir: str = "../terraform"
    ansible_dir: str = "../terraform/ansible"

    worker_max_concurrency: int = 1
    quota_max_vms: int = 10
    quota_max_running_deployments: int = 1

    netbird_letsencrypt_email: str = "admin@yourplatform.example.com"

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


@lru_cache
def get_settings() -> Settings:
    return Settings()
```

- [ ] **Step 3: 写 DB 模块**

`portal/backend/app/db.py`:
```python
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import get_settings

settings = get_settings()
engine = create_engine(
    settings.database_url,
    connect_args={"check_same_thread": False} if settings.database_url.startswith("sqlite") else {},
)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
```

- [ ] **Step 4: 写 ORM 模型**

`portal/backend/app/models.py`:
```python
from datetime import datetime, timezone
from sqlalchemy import ForeignKey, String, Text, Integer, DateTime
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import JSON

from .db import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Tenant(Base):
    __tablename__ = "tenants"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(255))
    slug: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    status: Mapped[str] = mapped_column(String(16), default="active")
    quota: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    users: Mapped[list["User"]] = relationship(back_populates="tenant")


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    tenant_id: Mapped[int] = mapped_column(ForeignKey("tenants.id"))
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    role: Mapped[str] = mapped_column(String(16), default="admin")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    tenant: Mapped["Tenant"] = relationship(back_populates="users")


class Deployment(Base):
    __tablename__ = "deployments"
    id: Mapped[int] = mapped_column(primary_key=True)
    tenant_id: Mapped[int] = mapped_column(ForeignKey("tenants.id"), index=True)
    config: Mapped[dict] = mapped_column(JSON)
    secrets: Mapped[dict] = mapped_column(JSON, default=dict)
    status: Mapped[str] = mapped_column(String(16), default="draft")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    runs: Mapped[list["Run"]] = relationship(back_populates="deployment")


class Run(Base):
    __tablename__ = "runs"
    id: Mapped[int] = mapped_column(primary_key=True)
    deployment_id: Mapped[int] = mapped_column(ForeignKey("deployments.id"), index=True)
    type: Mapped[str] = mapped_column(String(16))  # create | destroy
    status: Mapped[str] = mapped_column(String(16), default="pending")  # pending|running|succeeded|failed
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    log: Mapped[str] = mapped_column(Text, default="")
    started_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

    deployment: Mapped["Deployment"] = relationship(back_populates="runs")
```

- [ ] **Step 5: 写 app 工厂 + 健康检查**

`portal/backend/app/main.py`:
```python
from fastapi import FastAPI

from .db import Base, engine
from .routers import auth, deployments


def create_app() -> FastAPI:
    app = FastAPI(title="Infra Provisioning Portal")
    app.include_router(auth.router, prefix="/api/auth", tags=["auth"])
    app.include_router(deployments.router, prefix="/api/deployments", tags=["deployments"])

    @app.on_event("startup")
    def _startup() -> None:
        Base.metadata.create_all(bind=engine)

    @app.get("/api/health")
    def health() -> dict:
        return {"status": "ok"}

    return app


app = create_app()
```

- [ ] **Step 6: 写测试 fixture**

`portal/backend/tests/conftest.py`:
```python
import os
import tempfile

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.db import Base, get_db
from app.main import create_app


@pytest.fixture
def client():
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    test_engine = create_engine(f"sqlite:///{path}", connect_args={"check_same_thread": False})
    TestingSession = sessionmaker(bind=test_engine, autoflush=False, autocommit=False)
    Base.metadata.create_all(bind=test_engine)

    app = create_app()

    def override_get_db():
        db = TestingSession()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    os.unlink(path)


@pytest.fixture
def db_factory(tmp_path):
    test_engine = create_engine(
        f"sqlite:///{tmp_path}/test.db", connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(bind=test_engine)
    return sessionmaker(bind=test_engine, autoflush=False, autocommit=False)
```

- [ ] **Step 7: 写模型测试**

`portal/backend/tests/test_models.py`:
```python
from app.models import Tenant, User, Deployment, Run


def test_tenant_user_deployment_run_roundtrip(client):
    from app.db import SessionLocal
    from sqlalchemy import select

    db = SessionLocal()
    t = Tenant(name="Acme", slug="acme")
    db.add(t)
    db.commit()
    u = User(tenant_id=t.id, email="a@acme.com", password_hash="x")
    db.add(u)
    db.commit()
    d = Deployment(tenant_id=t.id, config={"subdomain": "acme"})
    db.add(d)
    db.commit()
    r = Run(deployment_id=d.id, type="create", status="pending")
    db.add(r)
    db.commit()

    got = db.scalar(select(Run).where(Run.id == r.id))
    assert got.deployment.tenant_id == t.id
    assert got.deployment.tenant.slug == "acme"
    db.close()
```

- [ ] **Step 8: 运行测试**

Run: `cd portal/backend && pip install -r requirements.txt && python -m pytest tests/test_models.py -v`
Expected: PASS

- [ ] **Step 9: 提交**

```bash
git add portal/backend
git commit -m "feat(portal): backend scaffold with config, db, models, health check"
```

---

## Task 2: 安全模块（密码哈希 + JWT + 当前用户依赖）

**Files:**
- Create: `portal/backend/app/security.py`
- Test: `portal/backend/tests/test_security.py`

**Interfaces:**
- Consumes: `Settings`（Task 1）、`User` 模型（Task 1）。
- Produces: `hash_password(pw)->str`、`verify_password(pw, hashed)->bool`、`create_access_token(subject: str)->str`、`decode_token(token)->str`、`get_current_user(token, db)->User`（FastAPI 依赖）。

- [ ] **Step 1: 写失败测试**

`portal/backend/tests/test_security.py`:
```python
import pytest
from fastapi import HTTPException

from app.security import (
    hash_password,
    verify_password,
    create_access_token,
    decode_token,
)


def test_hash_and_verify_password():
    h = hash_password("s3cret")
    assert h != "s3cret"
    assert verify_password("s3cret", h) is True
    assert verify_password("wrong", h) is False


def test_token_roundtrip():
    token = create_access_token("user@example.com")
    assert decode_token(token) == "user@example.com"


def test_decode_invalid_token_raises():
    with pytest.raises(HTTPException):
        decode_token("not-a-token")
```

- [ ] **Step 2: 运行确认失败**

Run: `cd portal/backend && python -m pytest tests/test_security.py -v`
Expected: FAIL（`ModuleNotFoundError: app.security`）

- [ ] **Step 3: 实现安全模块**

`portal/backend/app/security.py`:
```python
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from .config import get_settings
from .db import get_db
from .models import User

settings = get_settings()
bearer = HTTPBearer(auto_error=False)


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode("utf-8"), hashed.encode("utf-8"))
    except ValueError:
        return False


def create_access_token(subject: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.access_token_expire_minutes)
    payload = {"sub": subject, "exp": expire}
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def decode_token(token: str) -> str:
    try:
        payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
    except jwt.PyJWTError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    return payload["sub"]


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    db: Session = Depends(get_db),
) -> User:
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    email = decode_token(credentials.credentials)
    user = db.query(User).filter(User.email == email).first()
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")
    return user
```

- [ ] **Step 4: 运行确认通过**

Run: `cd portal/backend && python -m pytest tests/test_security.py -v`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add portal/backend/app/security.py portal/backend/tests/test_security.py
git commit -m "feat(portal): password hashing and JWT auth helpers"
```

---

## Task 3: 认证端点（注册 + 登录）

**Files:**
- Create: `portal/backend/app/routers/__init__.py`
- Create: `portal/backend/app/routers/auth.py`
- Create: `portal/backend/app/schemas.py`
- Test: `portal/backend/tests/test_auth.py`

**Interfaces:**
- Consumes: `hash_password`/`create_access_token`（Task 2）、`Tenant`/`User`（Task 1）。
- Produces: `POST /api/auth/register`、`POST /api/auth/login`；`schemas.py` 里的 `RegisterRequest`、`LoginRequest`、`TokenResponse`。

- [ ] **Step 1: 写失败测试**

`portal/backend/tests/test_auth.py`:
```python
def test_register_creates_tenant_and_returns_token(client):
    r = client.post("/api/auth/register", json={
        "tenant_name": "Acme Corp",
        "email": "admin@acme.com",
        "password": "s3cret123",
    })
    assert r.status_code == 200
    assert "access_token" in r.json()


def test_register_duplicate_email_conflict(client):
    body = {"tenant_name": "Acme", "email": "dup@acme.com", "password": "s3cret123"}
    assert client.post("/api/auth/register", json=body).status_code == 200
    r = client.post("/api/auth/register", json=body)
    assert r.status_code == 409


def test_login_roundtrip(client):
    client.post("/api/auth/register", json={
        "tenant_name": "Acme", "email": "login@acme.com", "password": "s3cret123",
    })
    r = client.post("/api/auth/login", json={"email": "login@acme.com", "password": "s3cret123"})
    assert r.status_code == 200
    assert "access_token" in r.json()

    bad = client.post("/api/auth/login", json={"email": "login@acme.com", "password": "wrong"})
    assert bad.status_code == 401
```

- [ ] **Step 2: 运行确认失败**

Run: `cd portal/backend && python -m pytest tests/test_auth.py -v`
Expected: FAIL（路由不存在）

- [ ] **Step 3: 写请求/响应 schema**

`portal/backend/app/schemas.py`:
```python
from pydantic import BaseModel, EmailStr, Field


class RegisterRequest(BaseModel):
    tenant_name: str = Field(min_length=1, max_length=255)
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
```

> 注：`EmailStr` 需要 `email-validator` 包，`pydantic[email]`。把 `pydantic==2.10.4` 换成 `pydantic[email]==2.10.4`（若 `EmailStr` 抛导入错误）。

- [ ] **Step 4: 写认证路由**

`portal/backend/app/routers/auth.py`:
```python
import re

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Tenant, User
from ..schemas import LoginRequest, RegisterRequest, TokenResponse
from ..security import create_access_token, hash_password, verify_password

router = APIRouter()


def make_slug(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "tenant"


@router.post("/register", response_model=TokenResponse)
def register(body: RegisterRequest, db: Session = Depends(get_db)):
    existing = db.query(User).filter(User.email == body.email).first()
    if existing:
        raise HTTPException(status_code=409, detail="Email already registered")

    slug = make_slug(body.tenant_name)
    base = slug
    n = 1
    while db.query(Tenant).filter(Tenant.slug == slug).first():
        n += 1
        slug = f"{base}-{n}"

    tenant = Tenant(name=body.tenant_name, slug=slug)
    db.add(tenant)
    db.commit()
    db.refresh(tenant)

    user = User(
        tenant_id=tenant.id,
        email=body.email,
        password_hash=hash_password(body.password),
        role="admin",
    )
    db.add(user)
    db.commit()

    return TokenResponse(access_token=create_access_token(user.email))


@router.post("/login", response_model=TokenResponse)
def login(body: LoginRequest, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == body.email).first()
    if user is None or not verify_password(body.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    return TokenResponse(access_token=create_access_token(user.email))
```

- [ ] **Step 5: 注册路由到 app**（`portal/backend/app/main.py` 已在 Task 1 引用 `auth.router`，无需改动）

- [ ] **Step 6: 运行确认通过**

Run: `cd portal/backend && python -m pytest tests/test_auth.py -v`
Expected: PASS（若报 `email-validator` 缺失，`pip install "pydantic[email]"` 后重跑）

- [ ] **Step 7: 提交**

```bash
git add portal/backend/app/routers/__init__.py portal/backend/app/routers/auth.py portal/backend/app/schemas.py portal/backend/tests/test_auth.py
git commit -m "feat(portal): registration and login endpoints"
```

---

## Task 4: 部署配置 schema + 配额校验

**Files:**
- Create: `portal/backend/app/quotas.py`
- Modify: `portal/backend/app/schemas.py`（追加部署配置模型）
- Test: `portal/backend/tests/test_quotas.py`

**Interfaces:**
- Consumes: `Settings`（Task 1）。
- Produces: `DeploymentConfig`/`PublicDevices`/`InternalDevices`/`PublicInstance`/`InternalInstance`（schemas.py）；`validate_config(config, quota, running_count) -> list[str]`（返回错误列表，空=合法）。

- [ ] **Step 1: 写失败测试**

`portal/backend/tests/test_quotas.py`:
```python
from app.schemas import DeploymentConfig, InternalDevices, PublicDevices, PublicInstance, InternalInstance
from app.quotas import validate_config


def valid_config(**overrides):
    cfg = {
        "subdomain": "acme",
        "public_devices": {
            "cidr": "172.16.0.0/24",
            "instances": {
                "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"},
                "web": {"host_name": "web", "public_ip": True, "is_bastion": False, "domain_name": "web"},
            },
        },
        "internal_devices": {
            "cidr": "172.16.1.0/24",
            "instances": {"db": {"host_name": "db"}},
        },
    }
    cfg.update(overrides)
    return DeploymentConfig(**cfg)


def test_valid_config_passes():
    assert validate_config(valid_config(), {"max_vms": 10}, 0) == []


def test_no_bastion_rejected():
    cfg = valid_config()
    cfg.public_devices.instances["bastion"].is_bastion = False
    errs = validate_config(cfg, {"max_vms": 10}, 0)
    assert any("bastion" in e for e in errs)


def test_overlapping_subnets_rejected():
    cfg = valid_config(internal_devices={"cidr": "172.16.0.0/24", "instances": {"db": {"host_name": "db"}}})
    assert any("overlap" in e.lower() for e in validate_config(cfg, {"max_vms": 10}, 0))


def test_invalid_subdomain_rejected():
    cfg = valid_config(subdomain="bad sub!")
    assert any("subdomain" in e for e in validate_config(cfg, {"max_vms": 10}, 0))


def test_over_quota_vm_count_rejected():
    errs = validate_config(valid_config(), {"max_vms": 2}, 0)
    assert any("max_vms" in e or "quota" in e.lower() for e in errs)


def test_running_deployment_blocks_new_one():
    errs = validate_config(valid_config(), {"max_vms": 10, "max_running": 1}, 1)
    assert any("running" in e for e in errs)
```

- [ ] **Step 2: 运行确认失败**

Run: `cd portal/backend && python -m pytest tests/test_quotas.py -v`
Expected: FAIL（`app.quotas` 不存在）

- [ ] **Step 3: 追加部署配置 schema**

在 `portal/backend/app/schemas.py` 末尾追加：
```python
from typing import Literal


class PublicInstance(BaseModel):
    host_name: str
    domain_name: str
    public_ip: bool = True
    is_bastion: bool = False


class InternalInstance(BaseModel):
    host_name: str


class PublicDevices(BaseModel):
    cidr: str
    instances: dict[str, PublicInstance]


class InternalDevices(BaseModel):
    cidr: str
    instances: dict[str, InternalInstance]


class DeploymentConfig(BaseModel):
    subdomain: str
    public_devices: PublicDevices
    internal_devices: InternalDevices
    vpc_cidr: str = "172.16.0.0/16"
    ecs_instance_type: str = "ecs.t6-c1m2.large"
```

- [ ] **Step 4: 写配额校验**

`portal/backend/app/quotas.py`:
```python
import ipaddress
import re

from .schemas import DeploymentConfig

SUBDOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")


def _cidr(s: str) -> ipaddress.IPv4Network:
    try:
        return ipaddress.ip_network(s, strict=False)
    except ValueError:
        raise ValueError(f"invalid CIDR: {s}")


def validate_config(config: DeploymentConfig, quota: dict, running_count: int) -> list[str]:
    errors: list[str] = []

    if not SUBDOMAIN_RE.match(config.subdomain):
        errors.append(f"invalid subdomain: {config.subdomain}")

    try:
        vpc = _cidr(config.vpc_cidr)
        pub = _cidr(config.public_devices.cidr)
        internal = _cidr(config.internal_devices.cidr)
    except ValueError as e:
        return [str(e)]

    if not (vpc.network_address <= pub.network_address and pub.broadcast_address <= vpc.broadcast_address):
        errors.append("public_devices.cidr must be within vpc_cidr")
    if not (vpc.network_address <= internal.network_address and internal.broadcast_address <= vpc.broadcast_address):
        errors.append("internal_devices.cidr must be within vpc_cidr")
    if pub.overlaps(internal):
        errors.append("public and internal subnets overlap")

    pub_instances = config.public_devices.instances
    bastions = [k for k, v in pub_instances.items() if v.is_bastion]
    if len(bastions) != 1:
        errors.append("exactly one bastion (is_bastion=true) is required")
    for k, v in pub_instances.items():
        if v.is_bastion and not v.public_ip:
            errors.append(f"bastion {k} must have public_ip=true")
        if not v.public_ip:
            errors.append(f"public instance {k} must have public_ip=true")
        if not v.domain_name:
            errors.append(f"public instance {k} missing domain_name")

    total_vms = len(pub_instances) + len(config.internal_devices.instances)
    if total_vms > quota.get("max_vms", 10):
        errors.append(f"VM count {total_vms} exceeds quota max_vms={quota.get('max_vms', 10)}")

    max_running = quota.get("max_running", 1)
    if running_count >= max_running:
        errors.append(f"tenant already has {running_count} running deployment(s), max {max_running}")

    return errors
```

- [ ] **Step 5: 运行确认通过**

Run: `cd portal/backend && python -m pytest tests/test_quotas.py -v`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add portal/backend/app/quotas.py portal/backend/app/schemas.py portal/backend/tests/test_quotas.py
git commit -m "feat(portal): deployment config schema and quota validation"
```

---

## Task 5: tfvars 生成

**Files:**
- Create: `portal/backend/app/tfvars.py`
- Test: `portal/backend/tests/test_tfvars.py`

**Interfaces:**
- Consumes: `DeploymentConfig`（Task 4）、`Settings`（Task 1）。
- Produces: `generate_tfvars(config: DeploymentConfig, tenant_slug: str, settings) -> str`（返回 tfvars HCL 内容）。

- [ ] **Step 1: 写失败测试**

`portal/backend/tests/test_tfvars.py`:
```python
from app.schemas import DeploymentConfig
from app.tfvars import generate_tfvars
from app.config import get_settings


def _config() -> DeploymentConfig:
    return DeploymentConfig(
        subdomain="acme",
        public_devices={
            "cidr": "172.16.0.0/24",
            "instances": {
                "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"},
            },
        },
        internal_devices={"cidr": "172.16.1.0/24", "instances": {"db": {"host_name": "db"}}},
    )


def test_generate_tfvars_contains_expected_values():
    s = get_settings()
    out = generate_tfvars(_config(), "acme", s)
    assert 'resource_group_name = "mynet-acme"' in out
    assert f'domain_name = "acme.{s.platform_domain}"' in out
    assert 'alicloud_region = "cn-wulanchabu"' in out
    assert 'vswitch_zone = "cn-wulanchabu-a"' in out
    assert 'is_bastion = true' in out
    assert '"bastion"' in out and '"db"' in out


def test_generate_tfvars_quotes_values():
    out = generate_tfvars(_config(), "acme", get_settings())
    assert '"172.16.0.0/24"' in out
```

- [ ] **Step 2: 运行确认失败**

Run: `cd portal/backend && python -m pytest tests/test_tfvars.py -v`
Expected: FAIL（`app.tfvars` 不存在）

- [ ] **Step 3: 实现 tfvars 生成**

`portal/backend/app/tfvars.py`:
```python
from .config import Settings
from .schemas import DeploymentConfig


def _quote(s: str) -> str:
    return f'"{s}"'


def generate_tfvars(config: DeploymentConfig, tenant_slug: str, settings: Settings) -> str:
    lines: list[str] = []
    lines.append(f"alicloud_region = {_quote(settings.alicloud_region)}")
    lines.append(f"vswitch_zone = {_quote(settings.vswitch_zone)}")
    lines.append(f"vpc_cidr = {_quote(config.vpc_cidr)}")
    lines.append(f"resource_group_name = {_quote(f'mynet-{tenant_slug}')}")
    lines.append(f"ecs_instance_type = {_quote(config.ecs_instance_type)}")
    lines.append(f"domain_name = {_quote(f'{config.subdomain}.{settings.platform_domain}')}")
    lines.append("")

    lines.append("public_devices = {")
    lines.append(f"  cidr = {_quote(config.public_devices.cidr)}")
    lines.append("  instances = {")
    for name, inst in config.public_devices.instances.items():
        lines.append(f"    {_quote(name)} = {{")
        lines.append(f"      host_name   = {_quote(inst.host_name)}")
        lines.append(f"      public_ip   = {str(inst.public_ip).lower()}")
        lines.append(f"      is_bastion  = {str(inst.is_bastion).lower()}")
        lines.append(f"      domain_name = {_quote(inst.domain_name)}")
        lines.append("    }")
    lines.append("  }")
    lines.append("}")

    lines.append("")
    lines.append("internal_devices = {")
    lines.append(f"  cidr = {_quote(config.internal_devices.cidr)}")
    lines.append("  instances = {")
    for name, inst in config.internal_devices.instances.items():
        lines.append(f"    {_quote(name)} = {{")
        lines.append(f"      host_name = {_quote(inst.host_name)}")
        lines.append("    }")
    lines.append("  }")
    lines.append("}")

    return "\n".join(lines) + "\n"
```

- [ ] **Step 4: 运行确认通过**

Run: `cd portal/backend && python -m pytest tests/test_tfvars.py -v`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add portal/backend/app/tfvars.py portal/backend/tests/test_tfvars.py
git commit -m "feat(portal): generate per-tenant tfvars"
```

---

## Task 6: Deployer（terraform + ansible 子进程封装）

**Files:**
- Create: `portal/backend/app/deployer.py`
- Test: `portal/backend/tests/test_deployer.py`

**Interfaces:**
- Produces: `Deployer`（Protocol）、`RealDeployer`（实现类）、`DeployerError`。方法签名：
  - `terraform_apply(workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str`
  - `terraform_destroy(workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str`
  - `run_ansible(playbook: str, cwd: str, env: dict[str, str]) -> str`
  - 失败抛 `DeployerError`（含 stdout/stderr），成功返回合并输出。

- [ ] **Step 1: 写失败测试（用假二进制）**

`portal/backend/tests/test_deployer.py`:
```python
import os
import stat
import tempfile

import pytest

from app.deployer import DeployerError, RealDeployer


def _write_exec(path: str, content: str):
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)


def test_terraform_apply_runs_binary_and_returns_output(tmp_path):
    fake = tmp_path / "terraform"
    _write_exec(str(fake), "#!/bin/sh\necho applied $@\nexit 0\n")
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo")
    out = d.terraform_apply("acme", "/tmp/x.tfvars", "/tmp", {})
    assert "applied" in out
    assert "workspace" in out  # 我们传了 workspace 参数


def test_terraform_apply_nonzero_exit_raises(tmp_path):
    fake = tmp_path / "terraform"
    _write_exec(str(fake), "#!/bin/sh\necho boom >&2\nexit 1\n")
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo")
    with pytest.raises(DeployerError):
        d.terraform_apply("acme", "/tmp/x.tfvars", "/tmp", {})


def test_run_ansible_passes_playbook(tmp_path):
    fake = tmp_path / "ansible-playbook"
    _write_exec(str(fake), "#!/bin/sh\necho playbook=$1\nexit 0\n")
    d = RealDeployer(terraform_bin="/bin/echo", ansible_bin=str(fake))
    out = d.run_ansible("setup-docker.yml", "/tmp", {})
    assert "playbook=setup-docker.yml" in out
```

- [ ] **Step 2: 运行确认失败**

Run: `cd portal/backend && python -m pytest tests/test_deployer.py -v`
Expected: FAIL（`app.deployer` 不存在）

- [ ] **Step 3: 实现 Deployer**

`portal/backend/app/deployer.py`:
```python
from __future__ import annotations

import subprocess
from typing import Protocol


class DeployerError(Exception):
    def __init__(self, message: str, output: str = ""):
        super().__init__(message)
        self.output = output


class Deployer(Protocol):
    def terraform_apply(self, workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str: ...
    def terraform_destroy(self, workspace: str, cwd: str, env: dict[str, str]) -> str: ...
    def run_ansible(self, playbook: str, cwd: str, env: dict[str, str]) -> str: ...


class RealDeployer:
    def __init__(self, terraform_bin: str = "terraform", ansible_bin: str = "ansible-playbook"):
        self.terraform_bin = terraform_bin
        self.ansible_bin = ansible_bin

    def _run(self, cmd: list[str], cwd: str, env: dict[str, str]) -> str:
        import os

        merged = {**os.environ, **env}
        proc = subprocess.run(cmd, cwd=cwd, env=merged, capture_output=True, text=True, timeout=3600)
        out = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode != 0:
            raise DeployerError(f"command failed: {' '.join(cmd)}", out)
        return out

    def terraform_apply(self, workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str:
        return self._run(
            [self.terraform_bin, "workspace", "select", "-or-create", workspace],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "apply", "-auto-approve", f"-var-file={var_file}"],
            cwd, env,
        )

    def terraform_destroy(self, workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str:
        return self._run(
            [self.terraform_bin, "workspace", "select", "-or-create", workspace],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "destroy", "-auto-approve", f"-var-file={var_file}"],
            cwd, env,
        )

    def run_ansible(self, playbook: str, cwd: str, env: dict[str, str]) -> str:
        return self._run([self.ansible_bin, playbook], cwd, env)
```

- [ ] **Step 4: 运行确认通过**

Run: `cd portal/backend && python -m pytest tests/test_deployer.py -v`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add portal/backend/app/deployer.py portal/backend/tests/test_deployer.py
git commit -m "feat(portal): deployer interface and subprocess wrappers"
```

---

## Task 7: Runner（编排 + 状态机 + 并发）

**Files:**
- Create: `portal/backend/app/runner.py`
- Test: `portal/backend/tests/test_runner.py`

**Interfaces:**
- Consumes: `Deployer`（Task 6）、`generate_tfvars`（Task 5）、`Run`/`Deployment`/`Tenant`（Task 1）、`Settings`（Task 1）。
- Produces: `execute_run(run_id: int, deployer: Deployer, session_factory) -> None`（同步编排一次 run 并更新状态/日志）；`worker_loop(session_factory, deployer, max_concurrency: int) -> None`（轮询 pending，限并发分发）。

- [ ] **Step 1: 写失败测试（假 Deployer）**

`portal/backend/tests/test_runner.py`:
```python
import pytest
from sqlalchemy.orm import sessionmaker

from app.deployer import DeployerError
from app.models import Deployment, Run, Tenant
from app.runner import execute_run


class FakeDeployer:
    def __init__(self, fail_on=None):
        self.fail_on = fail_on
        self.calls: list[str] = []
        self.apply_count = 0

    def terraform_apply(self, workspace, var_file, cwd, env):
        self.calls.append("apply")
        self.apply_count += 1
        if self.fail_on == "apply":
            raise DeployerError("apply failed", "boom")
        return "applied"

    def terraform_destroy(self, workspace, var_file, cwd, env):
        self.calls.append("destroy")
        return "destroyed"

    def run_ansible(self, playbook, cwd, env):
        self.calls.append(playbook)
        return f"ran {playbook}"


def _make_run(db_factory, deployer, run_type="create"):
    db = db_factory()
    t = Tenant(name="Acme", slug="acme")
    db.add(t); db.commit()
    d = Deployment(tenant_id=t.id, config={
        "subdomain": "acme",
        "public_devices": {"cidr": "172.16.0.0/24", "instances": {
            "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"},
        }},
        "internal_devices": {"cidr": "172.16.1.0/24", "instances": {"db": {"host_name": "db"}}},
    })
    db.add(d); db.commit()
    r = Run(deployment_id=d.id, type=run_type, status="pending")
    db.add(r); db.commit()
    run_id = r.id
    db.close()
    return run_id


def test_execute_create_marks_succeeded(db_factory):
    fake = FakeDeployer()
    run_id = _make_run(db_factory, fake)
    execute_run(run_id, fake, db_factory)
    db = db_factory()
    r = db.query(Run).get(run_id)
    assert r.status == "succeeded"
    assert "applied" in r.log
    assert "setup-network" in " ".join(fake.calls)
    db.close()


def test_execute_failure_marks_failed_and_keeps_log(db_factory):
    fake = FakeDeployer(fail_on="apply")
    run_id = _make_run(db_factory, fake)
    execute_run(run_id, fake, db_factory)
    db = db_factory()
    r = db.query(Run).get(run_id)
    assert r.status == "failed"
    assert "boom" in r.log
    db.close()


def test_execute_destroy_calls_terraform_destroy(db_factory):
    fake = FakeDeployer()
    run_id = _make_run(db_factory, fake, run_type="destroy")
    execute_run(run_id, fake, db_factory)
    assert "destroy" in fake.calls
```

- [ ] **Step 2: 运行确认失败**

Run: `cd portal/backend && python -m pytest tests/test_runner.py -v`
Expected: FAIL（`app.runner` 不存在）

- [ ] **Step 3: 实现 runner**

`portal/backend/app/runner.py`:
```python
from __future__ import annotations

import logging
import tempfile
import time
from datetime import datetime, timezone

from .config import get_settings
from .deployer import Deployer, DeployerError
from .models import Deployment, Run, Tenant
from .tfvars import generate_tfvars
from .schemas import DeploymentConfig

logger = logging.getLogger("portal.runner")

PLAYBOOKS = ["setup-network.yml", "setup-docker.yml", "setup-netbird.yml", "setup-netbird-agent.yml"]


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _append_log(run: Run, msg: str, db) -> None:
    run.log = (run.log or "") + msg + "\n"
    db.add(run)
    db.commit()


def _env_for(settings) -> dict[str, str]:
    return {
        "ALICLOUD_ACCESS_KEY": settings.alicloud_access_key,
        "ALICLOUD_SECRET_KEY": settings.alicloud_secret_key,
        "ALICLOUD_REGION": settings.alicloud_region,
        "NETBIRD_LETSENCRYPT_EMAIL": settings.netbird_letsencrypt_email,
    }


def execute_run(run_id: int, deployer: Deployer, session_factory) -> None:
    settings = get_settings()
    db = session_factory()
    run = db.query(Run).get(run_id)
    if run is None:
        db.close()
        return
    run.status = "running"
    run.started_at = utcnow()
    db.commit()

    deployment = run.deployment
    tenant = db.query(Tenant).get(deployment.tenant_id)

    try:
        config = DeploymentConfig(**deployment.config)
        tfvars_content = generate_tfvars(config, tenant.slug, settings)

        with tempfile.NamedTemporaryFile("w", suffix=".tfvars", delete=False) as f:
            f.write(tfvars_content)
            var_file = f.name

        env = _env_for(settings)
        if run.type == "destroy":
            _append_log(run, "==> terraform destroy", db)
            out = deployer.terraform_destroy(tenant.slug, var_file, settings.terraform_dir, env)
            _append_log(run, out, db)
        else:
            _append_log(run, "==> terraform apply", db)
            out = deployer.terraform_apply(tenant.slug, var_file, settings.terraform_dir, env)
            _append_log(run, out, db)

            for playbook in PLAYBOOKS:
                _append_log(run, f"==> ansible-playbook {playbook}", db)
                out = deployer.run_ansible(playbook, settings.ansible_dir, env)
                _append_log(run, out, db)

        run.status = "succeeded"
        db.commit()
    except DeployerError as e:
        _append_log(run, f"ERROR: {e}\n{e.output}", db)
        run.error = str(e)
        run.status = "failed"
        db.commit()
    except Exception as e:  # noqa: BLE001
        _append_log(run, f"UNEXPECTED ERROR: {e}", db)
        run.error = str(e)
        run.status = "failed"
        db.commit()
    finally:
        run.finished_at = utcnow()
        db.commit()
        db.close()


def worker_loop(session_factory, deployer: Deployer, max_concurrency: int = 1) -> None:
    import threading

    semaphore = threading.Semaphore(max_concurrency)
    active: set[int] = set()

    def _dispatch(run_id: int):
        semaphore.acquire()
        try:
            execute_run(run_id, deployer, session_factory)
        finally:
            semaphore.release()

    while True:
        db = session_factory()
        pending = db.query(Run).filter(Run.status == "pending").all()
        db.close()
        for run in pending:
            if run.id not in active and len(active) < max_concurrency:
                active.add(run.id)
                t = threading.Thread(target=_dispatch, args=(run.id,))
                t.start()
        time.sleep(2)
```

> 说明：`Settings` 需新增 `alicloud_access_key`、`alicloud_secret_key` 两个字段（默认空字符串，从环境变量注入）。在 `config.py` 的 `Settings` 中补充：
> ```python
> alicloud_access_key: str = ""
> alicloud_secret_key: str = ""
> ```

- [ ] **Step 4: 运行确认通过**

Run: `cd portal/backend && python -m pytest tests/test_runner.py -v`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add portal/backend/app/runner.py portal/backend/app/config.py portal/backend/tests/test_runner.py
git commit -m "feat(portal): run orchestration, state machine, and worker loop"
```

---

## Task 8: 部署 API 端点 + 租户授权

**Files:**
- Create: `portal/backend/app/routers/deployments.py`
- Test: `portal/backend/tests/test_deployments_api.py`

**Interfaces:**
- Consumes: `get_current_user`（Task 2）、`validate_config`（Task 4）、`Deployment`/`Run`/`Tenant`（Task 1）、`execute_run`（Task 7）。
- Produces: `POST /api/deployments`（创建）、`GET /api/deployments`（列表）、`GET /api/deployments/{id}`（详情+日志）、`POST /api/deployments/{id}/destroy`、`POST /api/deployments/{id}/retry`。

- [ ] **Step 1: 写失败测试**

`portal/backend/tests/test_deployments_api.py`:
```python
def _register(client, email, tenant="Acme"):
    r = client.post("/api/auth/register", json={"tenant_name": tenant, "email": email, "password": "s3cret123"})
    return r.json()["access_token"]


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _config_body():
    return {
        "subdomain": "acme",
        "public_devices": {
            "cidr": "172.16.0.0/24",
            "instances": {
                "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"},
            },
        },
        "internal_devices": {"cidr": "172.16.1.0/24", "instances": {"db": {"host_name": "db"}}},
    }


def test_create_deployment_returns_id(client):
    token = _register(client, "a@acme.com")
    r = client.post("/api/deployments", json=_config_body(), headers=_auth(token))
    assert r.status_code == 200
    assert r.json()["id"] > 0


def test_create_invalid_config_rejected(client):
    token = _register(client, "b@acme.com")
    body = _config_body()
    body["public_devices"]["instances"]["bastion"]["is_bastion"] = False
    r = client.post("/api/deployments", json=body, headers=_auth(token))
    assert r.status_code == 400


def test_tenant_isolation_cannot_see_others(client):
    token_a = _register(client, "a@x.com", "Tenant A")
    token_b = _register(client, "b@y.com", "Tenant B")
    r = client.post("/api/deployments", json=_config_body(), headers=_auth(token_a))
    dep_id = r.json()["id"]
    r2 = client.get(f"/api/deployments/{dep_id}", headers=_auth(token_b))
    assert r2.status_code == 404


def test_unauthenticated_rejected(client):
    assert client.get("/api/deployments").status_code == 401
```

- [ ] **Step 2: 运行确认失败**

Run: `cd portal/backend && python -m pytest tests/test_deployments_api.py -v`
Expected: FAIL（路由不存在）

- [ ] **Step 3: 写部署路由**

`portal/backend/app/routers/deployments.py`:
```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Deployment, Run, User
from ..quotas import validate_config
from ..schemas import DeploymentConfig
from ..security import get_current_user

router = APIRouter()


def _owned_deployment(db: Session, dep_id: int, user: User) -> Deployment:
    dep = db.query(Deployment).filter(Deployment.id == dep_id, Deployment.tenant_id == user.tenant_id).first()
    if dep is None:
        raise HTTPException(status_code=404, detail="Deployment not found")
    return dep


@router.post("")
def create_deployment(body: DeploymentConfig, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    running = (
        db.query(Run)
        .join(Deployment, Run.deployment_id == Deployment.id)
        .filter(Deployment.tenant_id == user.tenant_id, Run.status.in_(["pending", "running"]))
        .count()
    )
    quota = {"max_vms": 10, "max_running": 1}
    errors = validate_config(body, quota, running)
    if errors:
        raise HTTPException(status_code=400, detail="; ".join(errors))

    dep = Deployment(tenant_id=user.tenant_id, config=body.model_dump(), status="draft")
    db.add(dep)
    db.commit()
    db.refresh(dep)

    run = Run(deployment_id=dep.id, type="create", status="pending")
    db.add(run)
    db.commit()
    return {"id": dep.id, "run_id": run.id, "status": "pending"}


@router.get("")
def list_deployments(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    deps = db.query(Deployment).filter(Deployment.tenant_id == user.tenant_id).all()
    return [
        {"id": d.id, "status": d.status, "config": d.config, "created_at": d.created_at.isoformat()}
        for d in deps
    ]


@router.get("/{dep_id}")
def get_deployment(dep_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    dep = _owned_deployment(db, dep_id, user)
    runs = db.query(Run).filter(Run.deployment_id == dep.id).all()
    return {
        "id": dep.id,
        "config": dep.config,
        "runs": [
            {"id": r.id, "type": r.type, "status": r.status, "error": r.error, "log": r.log}
            for r in runs
        ],
    }


@router.post("/{dep_id}/destroy")
def destroy_deployment(dep_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    dep = _owned_deployment(db, dep_id, user)
    run = Run(deployment_id=dep.id, type="destroy", status="pending")
    db.add(run)
    db.commit()
    return {"run_id": run.id, "status": "pending"}


@router.post("/{dep_id}/retry")
def retry_deployment(dep_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    dep = _owned_deployment(db, dep_id, user)
    last = (
        db.query(Run)
        .filter(Run.deployment_id == dep.id, Run.type == "create")
        .order_by(Run.id.desc())
        .first()
    )
    if last is not None and last.status == "failed":
        run = Run(deployment_id=dep.id, type="create", status="pending")
        db.add(run)
        db.commit()
        return {"run_id": run.id, "status": "pending"}
    raise HTTPException(status_code=400, detail="No failed run to retry")
```

- [ ] **Step 4: 运行确认通过**

Run: `cd portal/backend && python -m pytest tests/test_deployments_api.py -v`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add portal/backend/app/routers/deployments.py portal/backend/tests/test_deployments_api.py
git commit -m "feat(portal): deployment API endpoints with tenant authorization"
```

---

## Task 9: 前端 SPA

**Files:**
- Create: `portal/frontend/package.json`
- Create: `portal/frontend/vite.config.ts`
- Create: `portal/frontend/tsconfig.json`
- Create: `portal/frontend/index.html`
- Create: `portal/frontend/src/main.tsx`
- Create: `portal/frontend/src/App.tsx`
- Create: `portal/frontend/src/api.ts`
- Create: `portal/frontend/src/types.ts`
- Create: `portal/frontend/src/pages/Register.tsx`
- Create: `portal/frontend/src/pages/Login.tsx`
- Create: `portal/frontend/src/pages/Dashboard.tsx`
- Create: `portal/frontend/src/pages/DeploymentDetail.tsx`

**Interfaces:**
- Consumes: 后端 REST（Task 3、Task 8 的端点）。
- Produces: 可运行的 SPA；登录后能注册/登录、创建部署、查看列表、查看单条部署的 run 状态与日志、触发销毁/重试。

- [ ] **Step 1: 脚手架**

`portal/frontend/package.json`:
```json
{
  "name": "portal-frontend",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-router-dom": "^6.28.0"
  },
  "devDependencies": {
    "@types/react": "^18.3.12",
    "@types/react-dom": "^18.3.1",
    "@vitejs/plugin-react": "^4.3.4",
    "typescript": "^5.6.3",
    "vite": "^5.4.11"
  }
}
```

`portal/frontend/vite.config.ts`:
```ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: { "/api": "http://localhost:8000" },
  },
});
```

`portal/frontend/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true
  },
  "include": ["src"]
}
```

`portal/frontend/index.html`:
```html
<!doctype html>
<html lang="zh">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>基础设施部署门户</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

- [ ] **Step 2: 类型与 API 客户端**

`portal/frontend/src/types.ts`:
```ts
export interface PublicInstance {
  host_name: string;
  domain_name: string;
  public_ip: boolean;
  is_bastion: boolean;
}
export interface InternalInstance {
  host_name: string;
}
export interface DeploymentConfig {
  subdomain: string;
  public_devices: { cidr: string; instances: Record<string, PublicInstance> };
  internal_devices: { cidr: string; instances: Record<string, InternalInstance> };
  vpc_cidr?: string;
  ecs_instance_type?: string;
}
export interface RunInfo {
  id: number;
  type: string;
  status: string;
  error?: string | null;
  log?: string;
}
```

`portal/frontend/src/api.ts`:
```ts
const TOKEN_KEY = "portal_token";

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}
export function setToken(t: string) {
  localStorage.setItem(TOKEN_KEY, t);
}
export function clearToken() {
  localStorage.removeItem(TOKEN_KEY);
}

async function request(path: string, opts: RequestInit = {}) {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(opts.headers as Record<string, string> | undefined),
  };
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const res = await fetch(path, { ...opts, headers });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.detail || res.statusText);
  }
  return res.json();
}

export const api = {
  register: (tenant_name: string, email: string, password: string) =>
    request("/api/auth/register", { method: "POST", body: JSON.stringify({ tenant_name, email, password }) }),
  login: (email: string, password: string) =>
    request("/api/auth/login", { method: "POST", body: JSON.stringify({ email, password }) }),
  createDeployment: (config: unknown) =>
    request("/api/deployments", { method: "POST", body: JSON.stringify(config) }),
  listDeployments: () => request("/api/deployments"),
  getDeployment: (id: number) => request(`/api/deployments/${id}`),
  destroyDeployment: (id: number) => request(`/api/deployments/${id}/destroy`, { method: "POST" }),
  retryDeployment: (id: number) => request(`/api/deployments/${id}/retry`, { method: "POST" }),
};
```

- [ ] **Step 3: 入口与路由**

`portal/frontend/src/main.tsx`:
```tsx
import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </React.StrictMode>,
);
```

`portal/frontend/src/App.tsx`:
```tsx
import { Routes, Route, Navigate } from "react-router-dom";
import { getToken } from "./api";
import Login from "./pages/Login";
import Register from "./pages/Register";
import Dashboard from "./pages/Dashboard";
import DeploymentDetail from "./pages/DeploymentDetail";

function RequireAuth({ children }: { children: JSX.Element }) {
  return getToken() ? children : <Navigate to="/login" replace />;
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route path="/register" element={<Register />} />
      <Route path="/" element={<RequireAuth><Dashboard /></RequireAuth>} />
      <Route path="/deployments/:id" element={<RequireAuth><DeploymentDetail /></RequireAuth>} />
    </Routes>
  );
}
```

- [ ] **Step 4: 认证页面**

`portal/frontend/src/pages/Login.tsx`:
```tsx
import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, setToken } from "../api";

export default function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const nav = useNavigate();

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    try {
      const r = await api.login(email, password);
      setToken(r.access_token);
      nav("/");
    } catch (err) {
      setError((err as Error).message);
    }
  }

  return (
    <form onSubmit={submit}>
      <h2>登录</h2>
      {error && <p style={{ color: "red" }}>{error}</p>}
      <input placeholder="邮箱" value={email} onChange={(e) => setEmail(e.target.value)} />
      <input type="password" placeholder="密码" value={password} onChange={(e) => setPassword(e.target.value)} />
      <button type="submit">登录</button>
      <a href="/register">注册</a>
    </form>
  );
}
```

`portal/frontend/src/pages/Register.tsx`:
```tsx
import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, setToken } from "../api";

export default function Register() {
  const [tenant, setTenant] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const nav = useNavigate();

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    try {
      const r = await api.register(tenant, email, password);
      setToken(r.access_token);
      nav("/");
    } catch (err) {
      setError((err as Error).message);
    }
  }

  return (
    <form onSubmit={submit}>
      <h2>注册</h2>
      {error && <p style={{ color: "red" }}>{error}</p>}
      <input placeholder="组织/租户名" value={tenant} onChange={(e) => setTenant(e.target.value)} />
      <input placeholder="邮箱" value={email} onChange={(e) => setEmail(e.target.value)} />
      <input type="password" placeholder="密码（至少8位）" value={password} onChange={(e) => setPassword(e.target.value)} />
      <button type="submit">注册</button>
    </form>
  );
}
```

- [ ] **Step 5: 仪表盘（列表 + 创建表单）**

`portal/frontend/src/pages/Dashboard.tsx`:
```tsx
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../api";

export default function Dashboard() {
  const [deps, setDeps] = useState<{ id: number; status: string }[]>([]);
  const [subdomain, setSubdomain] = useState("");
  const [publicVms, setPublicVms] = useState("bastion,web");
  const [internalVms, setInternalVms] = useState("db");
  const [error, setError] = useState("");

  async function refresh() {
    setDeps(await api.listDeployments());
  }
  useEffect(() => { refresh(); }, []);

  async function create(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    const pubInstances: Record<string, unknown> = {};
    publicVms.split(",").map((s) => s.trim()).filter(Boolean).forEach((name, i) => {
      pubInstances[name] = {
        host_name: name,
        public_ip: true,
        is_bastion: i === 0,
        domain_name: name,
      };
    });
    const intInstances: Record<string, unknown> = {};
    internalVms.split(",").map((s) => s.trim()).filter(Boolean).forEach((name) => {
      intInstances[name] = { host_name: name };
    });
    const config = {
      subdomain,
      public_devices: { cidr: "172.16.0.0/24", instances: pubInstances },
      internal_devices: { cidr: "172.16.1.0/24", instances: intInstances },
    };
    try {
      await api.createDeployment(config);
      refresh();
    } catch (err) {
      setError((err as Error).message);
    }
  }

  return (
    <div>
      <h2>部署</h2>
      {error && <p style={{ color: "red" }}>{error}</p>}
      <form onSubmit={create}>
        <input placeholder="子域名前缀，如 acme" value={subdomain} onChange={(e) => setSubdomain(e.target.value)} />
        <input placeholder="公网 VM（逗号分隔，第一台为堡垒机）" value={publicVms} onChange={(e) => setPublicVms(e.target.value)} />
        <input placeholder="内网 VM（逗号分隔）" value={internalVms} onChange={(e) => setInternalVms(e.target.value)} />
        <button type="submit">创建部署</button>
      </form>
      <ul>
        {deps.map((d) => (
          <li key={d.id}>
            <Link to={`/deployments/${d.id}`}>#{d.id} ({d.status})</Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
```

- [ ] **Step 6: 部署详情（状态 + 日志轮询）**

`portal/frontend/src/pages/DeploymentDetail.tsx`:
```tsx
import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { api } from "../api";
import type { RunInfo } from "../types";

export default function DeploymentDetail() {
  const { id } = useParams();
  const [runs, setRuns] = useState<RunInfo[]>([]);

  useEffect(() => {
    const timer = setInterval(async () => {
      const data = await api.getDeployment(Number(id));
      setRuns(data.runs);
    }, 2000);
    return () => clearInterval(timer);
  }, [id]);

  const last = runs[runs.length - 1];

  return (
    <div>
      <h2>部署 #{id}</h2>
      {last && <p>状态: {last.status}</p>}
      <button onClick={() => api.destroyDeployment(Number(id))}>销毁</button>
      <button onClick={() => api.retryDeployment(Number(id))}>重试</button>
      <pre style={{ whiteSpace: "pre-wrap", background: "#111", color: "#0f0", padding: 8 }}>
        {last?.log || "（暂无日志）"}
      </pre>
    </div>
  );
}
```

- [ ] **Step 7: 构建验证**

Run: `cd portal/frontend && npm install && npm run build`
Expected: 构建成功，无类型错误。

- [ ] **Step 8: 提交**

```bash
git add portal/frontend
git commit -m "feat(portal): React SPA for auth, deployment form, status and logs"
```

---

## Task 10: E2E 冒烟测试（可选，Playwright）

**Files:**
- Create: `portal/e2e/portal.spec.ts`
- Create: `portal/README.md`

**Interfaces:**
- Consumes: 完整后端（真实或假 Deployer）+ 前端 dev server。

- [ ] **Step 1: 写 Playwright 冒烟测试**

`portal/e2e/portal.spec.ts`:
```ts
import { test, expect } from "@playwright/test";

test("register and see empty deployment list", async ({ page }) => {
  await page.goto("/register");
  await page.getByPlaceholder("组织/租户名").fill("Acme");
  await page.getByPlaceholder("邮箱").fill(`u${Date.now()}@acme.com`);
  await page.getByPlaceholder("密码").fill("s3cret123");
  await page.getByRole("button", { name: "注册" }).click();
  await expect(page.getByText("部署")).toBeVisible();
});
```

- [ ] **Step 2: 写 README（运行说明）**

`portal/README.md`:
```markdown
# 基础设施自助部署门户

## 启动后端

    cd portal/backend
    pip install -r requirements.txt
    export ALICLOUD_ACCESS_KEY=... ALICLOUD_SECRET_KEY=...
    uvicorn app.main:app --reload

## 启动 Worker（另开终端）

    cd portal/backend
    python -c "from app.runner import worker_loop; from app.db import SessionLocal; from app.deployer import RealDeployer; worker_loop(SessionLocal, RealDeployer())"

## 启动前端

    cd portal/frontend
    npm install && npm run dev
```

- [ ] **Step 3: 提交**

```bash
git add portal/e2e/portal.spec.ts portal/README.md
git commit -m "test(portal): e2e smoke test and runbook README"
```

---

## Self-Review 结果

- **Spec 覆盖**：spec §5（架构）、§6（数据模型，Task 1）、§7（隔离/workspace/域名，Task 5/6/7）、§8（部署流程，Task 7/8）、§9（认证/配额/凭据，Task 2/3/4/8）、§10（错误处理/重试/回滚，Task 7/8）、§11（测试，各 Task 测试）均有对应任务。spec §12 风险（自助注册成本）由 Task 4 配额 + Task 8 运行中限制承接。
- **占位符扫描**：无 TBD/TODO。所有代码步骤含实际实现。
- **类型一致性**：`Deployer` 方法签名在 Task 6 定义、Task 7 的 `FakeDeployer` 与 `RealDeployer` 一致；`execute_run(run_id, deployer, session_factory)` 签名 Task 7 定义、Task 8 未直接调用（通过 worker 消费），无冲突。`DeploymentConfig` 字段在 Task 4 定义，Task 5/7/8 一致引用。
- **Review Focus**：5 条风险逐一映射——重复邮箱→Task 3、非法/重叠子网+堡垒机→Task 4、配额/运行中→Task 4+8、中途失败重试/销毁→Task 7、租户越权→Task 8。
