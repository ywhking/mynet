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
