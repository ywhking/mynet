from __future__ import annotations

import logging
import tempfile
import threading
from datetime import datetime, timezone

from .config import get_settings, validate_runtime_settings
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

ORPHAN_ERROR = "run was orphaned: the worker stopped while it was still running"
ORPHAN_LOG = (
    "==> run recovered on worker startup\n"
    "The worker process that was executing this run is gone, so it can never "
    "reach a terminal state on its own. Marked 'failed' so the tenant can retry "
    "or destroy instead of being stuck forever."
)

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


def _netbird_domain(config: DeploymentConfig, settings) -> str:
    """The bastion's FQDN, i.e. the address NetBird serves from.

    `tfvars.py` writes `domain_name = "<subdomain>.<platform_domain>"` as the DNS
    *zone* and `terraform/dns.tf` creates one A record per public instance with
    `rr = <instance domain_name>` *inside that zone*, so the bastion resolves at
    `<bastion.domain_name>.<subdomain>.<platform_domain>` (e.g.
    `bastion.acme.mynet.vip`). Dropping the tenant subdomain would both point at a
    name with no A record and collide every tenant's bastion on the same hostname.
    """
    for inst in config.public_devices.instances.values():
        if inst.is_bastion and inst.domain_name:
            return f"{inst.domain_name}.{config.subdomain}.{settings.platform_domain}"
    return ""


def _playbook_extra_args(playbook: str, config: DeploymentConfig, settings) -> list[str]:
    """The `-e key=value` pairs a playbook needs, mirroring deploy-all.sh.

    The playbooks default several inputs to absolute paths on the author's
    workstation, so a deploy from anywhere else fails; and `setup-netbird.yml`
    *requires* a real Let's Encrypt address. Values are only forwarded when
    non-empty, which leaves the playbook's own default in force otherwise.
    """
    args: list[str] = []

    def add(key: str, value: str) -> None:
        if value:
            args.extend(["-e", f"{key}={value}"])

    # Note the ordering: `setup-netbird-agent.yml` must be matched before
    # `setup-netbird.yml` would be — endswith() keeps them distinct today, but
    # the explicit ordering documents the intent.
    if playbook.endswith("setup-netbird-agent.yml"):
        add("netbird_binary", settings.netbird_binary)
        domain = _netbird_domain(config, settings)
        add("netbird_management_url", f"https://{domain}" if domain else "")
    elif playbook.endswith("setup-netbird.yml"):
        add("netbird_package", settings.netbird_package)
        add("netbird_domain", _netbird_domain(config, settings))
        add(NETBIRD_LETSENCRYPT_VAR, settings.netbird_letsencrypt_email)
    elif playbook.endswith("setup-docker.yml"):
        add("docker_repo_base", settings.docker_repo_base)
        add("docker_mirrors", settings.docker_mirrors)

    return args


def _demote_orphaned_runs(session_factory) -> int:
    """Fail every `running` Run left behind by a previous worker process.

    All the other in-flight guards are in-process: `worker_loop` polls `pending`
    only, destroy refuses while a create is in flight, and create is blocked by
    the running-count quota. So a worker that dies mid-run leaves a `running` row
    that no code path ever revisits — the tenant can neither retry nor destroy.
    There is at most one worker (see `worker_loop`), so any `running` row seen at
    startup is necessarily an orphan.

    Never raises: a transient DB error here must not stop the worker from
    starting, and the caller runs it before entering the poll loop.
    """
    db = None
    try:
        db = session_factory()
        orphans = db.query(Run).filter(Run.status == "running").all()
        if not orphans:
            return 0
        # Collected before the commit: committing expires the ORM attributes, so
        # reading them afterwards would re-SELECT every row.
        summary = [f"run={r.id} deployment={r.deployment_id}" for r in orphans]
        for run in orphans:
            run.status = "failed"
            run.error = ORPHAN_ERROR
            run.log = (run.log or "") + ("\n" if run.log else "") + ORPHAN_LOG + "\n"
            run.finished_at = utcnow()
            # The parent is stuck at "running" for the same reason; "failed" is
            # what a failed create run would have left, and the destroy endpoint
            # admits it (unlike "running", which is not terminal for the UI).
            if run.deployment is not None and run.deployment.status == "running":
                run.deployment.status = "failed"
        db.commit()
        logger.warning(
            "demoted %d orphaned run(s) to failed at startup: %s",
            len(summary),
            ", ".join(summary),
        )
        return len(summary)
    except Exception:  # noqa: BLE001
        logger.exception("could not demote orphaned runs at startup")
        if db is not None:
            _safe_rollback(db, -1)
        return 0
    finally:
        if db is not None:
            try:
                db.close()
            except Exception:  # noqa: BLE001
                logger.exception("failed to close session after orphan recovery")


def _deployment_terminal_status(run_type: str, status: str) -> str:
    """The parent ``Deployment.status`` for a terminal run.

    ``destroy`` success must NOT reuse ``"succeeded"``: that value means "live
    infrastructure exists" (it is exactly what the destroy endpoint's admission
    check requires), so a destroyed deployment marked ``"succeeded"`` would both
    render as a healthy deployment in the UI and re-admit a second destroy.
    """
    if status == "succeeded" and run_type == "destroy":
        return "destroyed"
    return status


def _finalize_run(
    run: Run,
    run_id: int,
    status: str,
    error: str | None,
    log_parts: list[str],
    db,
    message: str | None = None,
    deployment: Deployment | None = None,
) -> None:
    """Write the terminal state (and the full log) onto the run and its deployment.

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
        # Re-assigned inside the loop: a rollback expires the attributes, and the
        # retry below must not lose the deployment's transition.
        if deployment is not None:
            deployment.status = _deployment_terminal_status(run.type, status)
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
    # 父 Deployment 的状态必须跟着 run 走：列表接口只读它，若不同步，部署永远停在
    # "draft"，前端既看不出是活的也看不出是失败的。
    deployment: Deployment | None = None
    run.status = "running"
    run.started_at = utcnow()
    try:
        deployment = run.deployment
        if deployment is not None:
            deployment.status = "running"
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
        # Re-resolved here: the "running" commit above expires the attributes, and a
        # rollback there would leave the earlier reference unusable.
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

        # Per-tenant working directory: `terraform_dir` is only the *source* of
        # the module. Running in the shared directory would collide the generated
        # SSH keys (and the state, and any operator terraform.tfvars) between
        # tenants — see RealDeployer.prepare_workdir.
        workdir = deployer.prepare_workdir(settings.terraform_dir, settings.tenants_dir, tenant.slug)

        env = _env_for(settings)
        if run.type == "destroy":
            _append_log(run, "==> terraform destroy", log_parts, db, run_id)
            out = deployer.terraform_destroy(var_file, workdir, env)
            _append_log(run, out, log_parts, db, run_id)
        else:
            _append_log(run, "==> terraform apply", log_parts, db, run_id)
            out = deployer.terraform_apply(var_file, workdir, env)
            _append_log(run, out, log_parts, db, run_id)

            # spec §8 步骤 4：刷新静态 inventory，否则 ansible 会打到过期/不存在的 hosts.yml
            # 必须指向本租户的工作目录：inventory 脚本默认按自身位置推导 terraform
            # 目录（共享的 terraform/），那会读到平台自己的 state 与私钥。
            _append_log(run, "==> generate_inventory.sh --write", log_parts, db, run_id)
            out = deployer.generate_inventory(
                settings.inventory_script, settings.ansible_dir, env, terraform_dir=workdir
            )
            _append_log(run, out, log_parts, db, run_id)

            for playbook in PLAYBOOKS:
                extra = _playbook_extra_args(playbook, config, settings)
                _append_log(run, f"==> ansible-playbook {playbook}", log_parts, db, run_id)
                out = deployer.run_ansible(playbook, settings.ansible_dir, env, extra)
                _append_log(run, out, log_parts, db, run_id)

        _finalize_run(run, run_id, "succeeded", None, log_parts, db, deployment=deployment)
    except DeployerError as e:
        _finalize_run(
            run,
            run_id,
            "failed",
            str(e),
            log_parts,
            db,
            message=f"ERROR: {e}\n{e.output}",
            deployment=deployment,
        )
    except Exception as e:  # noqa: BLE001
        logger.exception("run %s failed unexpectedly", run_id)
        _finalize_run(
            run,
            run_id,
            "failed",
            str(e),
            log_parts,
            db,
            message=f"UNEXPECTED ERROR: {e}",
            deployment=deployment,
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

    Two things happen once, before the loop:

    * settings are validated, so a misconfigured worker (publicly known JWT
      secret, placeholder netbird email) dies immediately instead of after
      provisioning half a tenant's infrastructure;
    * every `running` run is demoted to `failed`. All the other in-flight guards
      are in-process, so a run whose worker died stays `running` forever and
      blocks the tenant from both retrying and destroying.

    Keep `max_concurrency` at 1. Each tenant now has its own terraform directory
    (see `prepare_workdir`), but `Settings.ansible_dir` — the cwd every
    `ansible-playbook` and `generate_inventory.sh` runs in — is still shared, and
    the inventory it writes is a single global `hosts.yml`. `stop_event` is only
    used by tests, to shut the loop down.
    """
    validate_runtime_settings(get_settings())
    _demote_orphaned_runs(session_factory)

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
