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

# 必须以 playbooks/ 前缀调用（cwd = settings.ansible_dir，ansible.cfg 在其中）
PLAYBOOKS = [
    "playbooks/setup-network.yml",
    "playbooks/setup-docker.yml",
    "playbooks/setup-netbird.yml",
    "playbooks/setup-netbird-agent.yml",
]


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

            # spec §8 步骤 4：刷新静态 inventory，否则 ansible 会打到过期/不存在的 hosts.yml
            _append_log(run, "==> generate_inventory.sh --write", db)
            out = deployer.generate_inventory(settings.inventory_script, settings.ansible_dir, env)
            _append_log(run, out, db)

            for playbook in PLAYBOOKS:
                extra: list[str] = []
                if playbook.endswith("setup-netbird.yml"):
                    # setup-netbird.yml 要求 netbird_letsencrypt_email（见 terraform/deploy-all.sh:162）
                    extra = ["-e", f"netbird_letsencrypt_email={settings.netbird_letsencrypt_email}"]
                _append_log(run, f"==> ansible-playbook {playbook}", db)
                out = deployer.run_ansible(playbook, settings.ansible_dir, env, extra)
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
            active.discard(run_id)  # 必须清理，否则 active 只增不减，处理完 N 个后再也不分发
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
