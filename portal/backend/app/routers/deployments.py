from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.exc import IntegrityError
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

    # `subdomain` is unique across ALL tenants (the DNS zone is shared), so this
    # must be a global query, not scoped to `user.tenant_id`. The pre-check
    # produces the friendly 400 in the common case; the unique index plus the
    # IntegrityError handler below is what actually makes it safe against a
    # concurrent registration of the same name.
    taken = db.query(Deployment).filter(Deployment.subdomain == body.subdomain).first()
    if taken is not None:
        raise HTTPException(
            status_code=400,
            detail=f"subdomain {body.subdomain!r} is already taken; choose another prefix",
        )

    # One transaction for both rows: a second commit that fails would leave a
    # Deployment with no Run — never executed, and (since nothing else sets the
    # status) permanently invisible at "draft". `Run(deployment=dep)` instead of
    # `deployment_id=dep.id` so the FK resolves from the relationship in the same
    # flush, with no prior commit needed to populate `dep.id`.
    dep = Deployment(
        tenant_id=user.tenant_id,
        subdomain=body.subdomain,
        config=body.model_dump(),
        status="draft",
    )
    run = Run(deployment=dep, type="create", status="pending")
    db.add_all([dep, run])
    try:
        db.commit()
    except IntegrityError:
        # Lost the race against another tenant's registration of the same
        # subdomain. Roll back so the session is usable and report it as the
        # client error it is — a 500 here would look like a portal outage.
        db.rollback()
        raise HTTPException(
            status_code=400,
            detail=f"subdomain {body.subdomain!r} is already taken; choose another prefix",
        )
    return {"id": dep.id, "run_id": run.id, "status": "pending"}


@router.get("")
def list_deployments(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    deps = db.query(Deployment).filter(Deployment.tenant_id == user.tenant_id).all()
    return [
        {
            "id": d.id,
            "subdomain": d.subdomain,
            "status": d.status,
            "config": d.config,
            "created_at": d.created_at.isoformat(),
        }
        for d in deps
    ]


@router.get("/{dep_id}")
def get_deployment(dep_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    dep = _owned_deployment(db, dep_id, user)
    runs = db.query(Run).filter(Run.deployment_id == dep.id).all()
    return {
        "id": dep.id,
        "subdomain": dep.subdomain,
        "config": dep.config,
        "runs": [
            {"id": r.id, "type": r.type, "status": r.status, "error": r.error, "log": r.log}
            for r in runs
        ],
    }


@router.post("/{dep_id}/destroy")
def destroy_deployment(dep_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    dep = _owned_deployment(db, dep_id, user)

    # 只拒绝"确定不可销毁"的情况。教训：若只放行 status == "succeeded"，一次失败的
    # destroy 会把部署置为 "failed"，此后 destroy 一律被拒，而 retry 只处理失败的
    # create run —— 租户就再也没有任何 API 路径去清理 terraform 已经建了一半的真实
    # 云资源，只能看着它持续计费。所以 "failed" 必须放行。

    # 1) 已有 destroy 在途 → 拒绝（幂等，避免重复入队把 run 堆积起来）
    in_flight_destroy = (
        db.query(Run)
        .filter(Run.deployment_id == dep.id, Run.type == "destroy", Run.status.in_(["pending", "running"]))
        .first()
    )
    if in_flight_destroy is not None:
        raise HTTPException(status_code=400, detail="destroy already in progress")

    # 2) 已有 create 在途 → 拒绝（不要一边建一边销毁）
    in_flight_create = (
        db.query(Run)
        .filter(Run.deployment_id == dep.id, Run.type == "create", Run.status.in_(["pending", "running"]))
        .first()
    )
    if in_flight_create is not None:
        raise HTTPException(status_code=400, detail="create in progress; wait for it to finish")

    # 3) 已销毁（或从未创建）→ 无物可销毁
    if dep.status in ("draft", "destroyed"):
        raise HTTPException(status_code=400, detail="nothing to destroy")

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
