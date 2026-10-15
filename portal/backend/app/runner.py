from __future__ import annotations

import logging
import tempfile
import threading
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

# setup-netbird.yml 要求 netbird_letsencrypt_email（见 terraform/deploy-all.sh:162）
NETBIRD_LETSENCRYPT_VAR = "netbird_letsencrypt_email"

POLL_INTERVAL_SECONDS = 2.0


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _render_log(log_parts: list[str]) -> str:
    return ("\n".join(log_parts) + "\n") if log_parts else ""


def _safe_rollback(db, run_id: int) -> None:
    try:
        db.rollback()
    except Exception:  # noqa: BLE001
        logger.exception("run %s: rollback failed", run_id)


def _append_log(run: Run, msg: str, log_parts: list[str], db, run_id: int) -> None:
    """Best-effort progress log.

    ``log_parts`` is the in-memory source of truth: a failed commit followed by a
    rollback expires the ORM attributes, which would otherwise silently drop every
    entry accumulated so far. The complete log is written again by the terminal
    state commit, so a hiccup here never loses the run's output.
    """
    log_parts.append(msg)
    run.log = _render_log(log_parts)
    try:
        db.commit()
    except Exception:  # noqa: BLE001
        logger.warning(
            "run %s: could not persist progress log; it will be written with the "
            "terminal state",
            run_id,
            exc_info=True,
        )
        _safe_rollback(db, run_id)


def _env_for(settings) -> dict[str, str]:
    return {
        "ALICLOUD_ACCESS_KEY": settings.alicloud_access_key,
        "ALICLOUD_SECRET_KEY": settings.alicloud_secret_key,
        "ALICLOUD_REGION": settings.alicloud_region,
        "NETBIRD_LETSENCRYPT_EMAIL": settings.netbird_letsencrypt_email,
    }


def _finalize_run(
    run: Run,
    run_id: int,
    status: str,
    error: str | None,
    log_parts: list[str],
    db,
    message: str | None = None,
) -> None:
    """Write the terminal state (and the full log) onto the run.

    The commit is retried once on failure: a rollback expires the run's ORM
    attributes, so a retry must re-assign them or the run would be left sitting in a
    non-terminal state that ``worker_loop`` (which only polls ``pending``) never
    picks up again.
    """
    if message:
        log_parts.append(message)

    for attempt, what in enumerate((f"recording status={status}", "retrying terminal state")):
        run.status = status
        run.error = error
        run.log = _render_log(log_parts)
        run.finished_at = utcnow()
        try:
            db.commit()
            return
        except Exception:  # noqa: BLE001
            logger.exception("run %s: db commit failed while %s", run_id, what)
            _safe_rollback(db, run_id)
        if attempt == 1:
            logger.error(
                "run %s: could not persist terminal status %s; it may stay non-terminal",
                run_id,
                status,
            )


def _finish_run(run: Run, run_id: int, db) -> None:
    """`finally` guarantee: the session is always closed, and a run that reached the
    end of `execute_run` always gets a `finished_at` — written unconditionally, so it
    is still recorded even if the failure handler above blew up."""
    try:
        run.finished_at = utcnow()
        db.commit()
    except Exception:  # noqa: BLE001
        logger.exception("run %s: failed to record finished_at", run_id)
        _safe_rollback(db, run_id)
    finally:
        try:
            db.close()
        except Exception:  # noqa: BLE001
            logger.exception("run %s: failed to close session", run_id)


def execute_run(run_id: int, deployer: Deployer, session_factory) -> None:
    settings = get_settings()
    db = session_factory()
    run = db.query(Run).get(run_id)
    if run is None:
        logger.warning("run %s not found; nothing to do", run_id)
        db.close()
        return
    run.status = "running"
    run.started_at = utcnow()
    try:
        db.commit()
    except Exception:  # noqa: BLE001
        # 状态未落盘，run 仍是 pending，worker 会重新领走
        logger.exception("run %s: could not mark as running", run_id)
        _safe_rollback(db, run_id)

    log_parts: list[str] = []
    try:
        # Everything below is inside the try: a missing deployment/tenant row or a
        # lazy-load failure must land the run in a terminal state too, otherwise it
        # stays "running" forever and worker_loop (pending-only) never retries it.
        deployment = run.deployment
        if deployment is None:
            raise RuntimeError(f"deployment for run {run_id} is missing")
        tenant = db.query(Tenant).get(deployment.tenant_id)
        if tenant is None:
            raise RuntimeError(f"tenant {deployment.tenant_id} for run {run_id} is missing")

        config = DeploymentConfig(**deployment.config)
        tfvars_content = generate_tfvars(config, tenant.slug, settings)

        with tempfile.NamedTemporaryFile("w", suffix=".tfvars", delete=False) as f:
            f.write(tfvars_content)
            var_file = f.name

        env = _env_for(settings)
        if run.type == "destroy":
            _append_log(run, "==> terraform destroy", log_parts, db, run_id)
            out = deployer.terraform_destroy(tenant.slug, var_file, settings.terraform_dir, env)
            _append_log(run, out, log_parts, db, run_id)
        else:
            _append_log(run, "==> terraform apply", log_parts, db, run_id)
            out = deployer.terraform_apply(tenant.slug, var_file, settings.terraform_dir, env)
            _append_log(run, out, log_parts, db, run_id)

            # spec §8 步骤 4：刷新静态 inventory，否则 ansible 会打到过期/不存在的 hosts.yml
            _append_log(run, "==> generate_inventory.sh --write", log_parts, db, run_id)
            out = deployer.generate_inventory(settings.inventory_script, settings.ansible_dir, env)
            _append_log(run, out, log_parts, db, run_id)

            for playbook in PLAYBOOKS:
                extra: list[str] = []
                if playbook.endswith("setup-netbird.yml"):
                    extra = ["-e", f"{NETBIRD_LETSENCRYPT_VAR}={settings.netbird_letsencrypt_email}"]
                _append_log(run, f"==> ansible-playbook {playbook}", log_parts, db, run_id)
                out = deployer.run_ansible(playbook, settings.ansible_dir, env, extra)
                _append_log(run, out, log_parts, db, run_id)

        _finalize_run(run, run_id, "succeeded", None, log_parts, db)
    except DeployerError as e:
        _finalize_run(
            run, run_id, "failed", str(e), log_parts, db, message=f"ERROR: {e}\n{e.output}"
        )
    except Exception as e:  # noqa: BLE001
        logger.exception("run %s failed unexpectedly", run_id)
        _finalize_run(
            run, run_id, "failed", str(e), log_parts, db, message=f"UNEXPECTED ERROR: {e}"
        )
    finally:
        _finish_run(run, run_id, db)


def worker_loop(
    session_factory,
    deployer: Deployer,
    max_concurrency: int = 1,
    poll_interval: float = POLL_INTERVAL_SECONDS,
    stop_event: threading.Event | None = None,
) -> None:
    """Poll for pending runs forever, dispatching at most `max_concurrency` at a time.

    Keep `max_concurrency` at 1: every deployment shares one terraform directory
    (`Settings.terraform_dir`) and `terraform workspace select` writes state for the
    whole directory, so two concurrent runs can apply tenant A's plan under tenant
    B's workspace. `stop_event` is only used by tests, to shut the loop down.
    """
    _stop = stop_event if stop_event is not None else threading.Event()
    semaphore = threading.Semaphore(max_concurrency)
    active: set[int] = set()

    def _dispatch(rid: int) -> None:
        try:
            execute_run(rid, deployer, session_factory)
        except Exception:  # noqa: BLE001
            # execute_run contains its own error handling; never let one kill the worker.
            logger.exception("run %s raised out of execute_run", rid)
        finally:
            active.discard(rid)  # 必须清理，否则 active 只增不减，处理完 N 个后再也不分发
            semaphore.release()

    while not _stop.is_set():
        try:
            db = session_factory()
            try:
                # 先取出 id：close 之后 ORM 对象已 detached，不该再碰它们的属性
                pending_ids = [r.id for r in db.query(Run).filter(Run.status == "pending").all()]
            finally:
                db.close()
            for run_id in pending_ids:
                if run_id in active or len(active) >= max_concurrency:
                    continue
                semaphore.acquire()
                active.add(run_id)
                try:
                    threading.Thread(target=_dispatch, args=(run_id,)).start()
                except Exception:  # noqa: BLE001
                    # 线程没起来：必须归还槽位，否则这个 run 永久占着并发额度
                    logger.exception("failed to start worker thread for run %s", run_id)
                    active.discard(run_id)
                    semaphore.release()
        except Exception:  # noqa: BLE001
            # A transient error (sqlite "database is locked", an unreadable DB, ...)
            # must not escape the loop and permanently stop all dispatching.
            logger.exception("worker loop iteration failed; retrying in %ss", poll_interval)
        _stop.wait(poll_interval)
