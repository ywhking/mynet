from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..config import get_settings
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
    settings = get_settings()
    quota = {
        "max_vms": settings.quota_max_vms,
        "max_running": settings.quota_max_running_deployments,
    }
    errors = validate_config(body, quota, running)
    if errors:
        raise HTTPException(status_code=400, detail="; ".join(errors))

    # One transaction for both rows: a second commit that fails would leave a
    # Deployment with no Run — never executed, and (since nothing else sets the
    # status) permanently invisible at "draft". `Run(deployment=dep)` instead of
    # `deployment_id=dep.id` so the FK resolves from the relationship in the same
    # flush, with no prior commit needed to populate `dep.id`.
    dep = Deployment(tenant_id=user.tenant_id, config=body.model_dump(), status="draft")
    run = Run(deployment=dep, type="create", status="pending")
    db.add_all([dep, run])
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

    # 重复 POST 会堆积 destroy run，每个都对已销毁的 state 再跑一次 terraform destroy
    active = (
        db.query(Run)
        .filter(Run.deployment_id == dep.id, Run.type == "destroy", Run.status.in_(["pending", "running"]))
        .first()
    )
    if active is not None:
        raise HTTPException(
            status_code=400, detail=f"A destroy run is already {active.status} for this deployment"
        )

    # "succeeded" 是"存在成功创建的基础设施"的唯一标志（见 runner 的终态映射：
    # destroy 成功会把它推进到 "destroyed"），所以 draft/failed/destroyed 都不该被销毁
    if dep.status != "succeeded":
        raise HTTPException(
            status_code=400,
            detail=f"Nothing to destroy: deployment status is {dep.status!r}, expected 'succeeded'",
        )

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
