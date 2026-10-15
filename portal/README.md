# 基础设施自助部署门户

后端与 Worker 都在仓库自带的 venv（`portal/backend/.venv`）下执行，下面用 `.venv/bin/...`
显式调用该解释器（也可以先 `source .venv/bin/activate`，再直接用 `pip` / `python` / `uvicorn`）。

## 启动后端

    cd portal/backend
    .venv/bin/pip install -r requirements.txt
    export ALICLOUD_ACCESS_KEY="<your-access-key>" ALICLOUD_SECRET_KEY="<your-secret-key>"
    .venv/bin/uvicorn app.main:app --reload

两个阿里云凭据只有真实部署（terraform apply）才需要，E2E 冒烟测试与本地起服务都不需要。

## 启动 Worker（另开终端）

    cd portal/backend
    .venv/bin/python -c "from app.runner import worker_loop; from app.db import SessionLocal; from app.deployer import RealDeployer; worker_loop(SessionLocal, RealDeployer())"

## 启动前端

    cd portal/frontend
    npm install && npm run dev

vite dev server 默认监听 http://localhost:5173，并把 `/api` 代理到 http://localhost:8000。

## E2E 冒烟测试

前置条件：

- 后端已在 http://localhost:8000 运行（见上）
- 前端 vite dev 已在 http://localhost:5173 运行（见上）
- 首次运行需要下载浏览器：`npx playwright install chromium`

运行：

    cd portal/e2e
    npm install
    npx playwright test

该测试会用一个随机邮箱真实注册租户，然后断言落到「部署」看板页。
