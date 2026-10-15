import threading
import time

from app.deployer import DeployerError
from app.models import Deployment, Run, Tenant
from app.runner import PLAYBOOKS, execute_run, worker_loop


class FakeDeployer:
    """Records what the runner asked for.

    ``fail_on`` raises a ``DeployerError`` (the deployer's own failure mode);
    ``raise_on`` raises an unrelated exception, which the runner's generic handler
    has to catch.
    """

    def __init__(self, fail_on=None, raise_on=None):
        self.fail_on = fail_on
        self.raise_on = raise_on
        self.calls: list[str] = []
        self.ansible_calls: list[tuple[str, list[str]]] = []
        self.apply_count = 0

    def terraform_apply(self, workspace, var_file, cwd, env):
        self.calls.append("apply")
        self.apply_count += 1
        if self.fail_on == "apply":
            raise DeployerError("apply failed", "boom")
        if self.raise_on == "apply":
            raise RuntimeError("kaboom")
        return "applied"

    def terraform_destroy(self, workspace, var_file, cwd, env):
        self.calls.append("destroy")
        return "destroyed"

    def generate_inventory(self, script_path, cwd, env):
        self.calls.append("inventory")
        return "inventory written"

    def run_ansible(self, playbook, cwd, env, extra_args=None):
        self.calls.append(playbook)
        self.ansible_calls.append((playbook, list(extra_args or [])))
        return f"ran {playbook}"


def _make_run(db_factory, deployer, run_type="create", slug="acme"):
    db = db_factory()
    t = Tenant(name=slug, slug=slug)
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


def _get_run(db_factory, run_id):
    db = db_factory()
    try:
        return db.query(Run).get(run_id)
    finally:
        db.close()


def _deployment_id_for_run(db_factory, run_id):
    db = db_factory()
    try:
        return db.query(Run).get(run_id).deployment_id
    finally:
        db.close()


def _deployment_status(db_factory, run_id):
    """Status of the Deployment that `run_id` belongs to.

    Read as a plain value inside the session: a detached instance's expired
    attributes would raise on access after `close()`.
    """
    db = db_factory()
    try:
        run = db.query(Run).get(run_id)
        return db.query(Deployment).get(run.deployment_id).status
    finally:
        db.close()


def _add_run(db_factory, deployment_id, run_type):
    db = db_factory()
    r = Run(deployment_id=deployment_id, type=run_type, status="pending")
    db.add(r); db.commit()
    run_id = r.id
    db.close()
    return run_id


class _StatusProbeDeployer(FakeDeployer):
    """Reads the parent Deployment's status from *inside* a run.

    The only way to catch a missing "running" write: observing the row from a
    separate session while `terraform_apply` is in flight.
    """

    def __init__(self, session_factory, dep_id):
        super().__init__()
        self._session_factory = session_factory
        self._dep_id = dep_id
        self.observed: list[str | None] = []

    def terraform_apply(self, workspace, var_file, cwd, env):
        db = self._session_factory()
        try:
            self.observed.append(db.query(Deployment).get(self._dep_id).status)
        finally:
            db.close()
        return super().terraform_apply(workspace, var_file, cwd, env)


def _extra_args_for(fake, playbook):
    """The extra args of a single ansible invocation (each playbook runs once)."""
    matches = [args for pb, args in fake.ansible_calls if pb == playbook]
    assert len(matches) == 1, f"{playbook} ran {len(matches)} times"
    return matches[0]


def _wait_for_status(session_factory, run_id, status, timeout=10.0):
    """Poll until `run_id` reaches `status`; raise (never hang) on timeout."""
    deadline = time.monotonic() + timeout
    observed = None
    while time.monotonic() < deadline:
        observed = _get_run(session_factory, run_id).status
        if observed == status:
            return observed
        time.sleep(0.05)
    raise AssertionError(f"run {run_id} never reached {status!r} (last seen {observed!r})")


def test_execute_create_marks_succeeded(db_factory):
    fake = FakeDeployer()
    run_id = _make_run(db_factory, fake)
    execute_run(run_id, fake, db_factory)
    r = _get_run(db_factory, run_id)
    assert r.status == "succeeded"
    assert r.error is None
    assert r.finished_at is not None
    assert "applied" in r.log

    # 四个 playbook 都跑了，且顺序与 PLAYBOOKS 一致
    ran_playbooks = [pb for pb, _ in fake.ansible_calls]
    assert ran_playbooks == PLAYBOOKS

    # inventory 必须在任何 playbook 之前跑（顺序，不只是出现）
    inventory_index = fake.calls.index("inventory")
    first_playbook_index = min(i for i, c in enumerate(fake.calls) if c in PLAYBOOKS)
    assert inventory_index < first_playbook_index, fake.calls

    # netbird email extra var 只挂在 setup-netbird.yml 上（不是 setup-netbird-agent.yml）
    assert _extra_args_for(fake, "playbooks/setup-netbird.yml") == [
        "-e",
        "netbird_letsencrypt_email=admin@yourplatform.example.com",
    ]
    assert _extra_args_for(fake, "playbooks/setup-netbird-agent.yml") == []
    assert _extra_args_for(fake, "playbooks/setup-network.yml") == []
    assert _extra_args_for(fake, "playbooks/setup-docker.yml") == []


def test_execute_failure_marks_failed_and_keeps_log(db_factory):
    fake = FakeDeployer(fail_on="apply")
    run_id = _make_run(db_factory, fake)
    execute_run(run_id, fake, db_factory)
    r = _get_run(db_factory, run_id)
    assert r.status == "failed"
    assert "boom" in r.log
    # DeployerError.output 必须落进日志，否则失败原因只有一句无上下文的 "apply failed"
    assert "apply failed" in r.log
    assert r.error == "apply failed"
    assert r.finished_at is not None
    # 失败即终止：apply 失败后不能再跑 inventory / ansible
    assert "inventory" not in fake.calls
    assert fake.ansible_calls == []


def test_execute_unexpected_error_marks_failed(db_factory):
    """非 DeployerError 异常也必须落到 failed 终态，而不是停在 running。"""
    fake = FakeDeployer(raise_on="apply")
    run_id = _make_run(db_factory, fake)
    execute_run(run_id, fake, db_factory)
    r = _get_run(db_factory, run_id)
    assert r.status == "failed"
    assert r.error == "kaboom"
    assert "kaboom" in r.log
    assert "UNEXPECTED ERROR" in r.log
    assert r.finished_at is not None


def test_execute_missing_deployment_marks_failed_not_stuck_running(db_factory):
    """回归保护：解析 deployment 失败也必须落到 failed 终态。

    若 deployment/tenant 的解析在 try 之外（原实现），异常会直接逃出 execute_run，
    run 永远停在 running、finished_at 为 NULL，而 worker_loop 只轮询 pending，
    这个 run 既不会重试也不会进入终态。
    """
    db = db_factory()
    r = Run(deployment_id=99999, type="create", status="pending")
    db.add(r); db.commit()
    run_id = r.id
    db.close()

    fake = FakeDeployer()
    execute_run(run_id, fake, db_factory)

    r = _get_run(db_factory, run_id)
    assert r.status == "failed"
    assert r.finished_at is not None
    assert "missing" in r.log
    assert fake.calls == []


def test_execute_destroy_calls_terraform_destroy(db_factory):
    fake = FakeDeployer()
    run_id = _make_run(db_factory, fake, run_type="destroy")
    execute_run(run_id, fake, db_factory)
    assert "destroy" in fake.calls
    r = _get_run(db_factory, run_id)
    assert r.status == "succeeded"
    assert r.finished_at is not None
    # destroy 不建资源：不能 apply，也不能跑任何 playbook / 刷新 inventory
    assert "apply" not in fake.calls
    assert "inventory" not in fake.calls
    assert fake.ansible_calls == []
    assert not any(c in PLAYBOOKS for c in fake.calls)


def test_worker_loop_keeps_dispatching_after_a_run_finishes(db_factory):
    """回归保护：active 集合被清理，处理完一个 run 后仍能领走下一个。

    若 ``active.discard`` 缺失，``len(active)`` 会一直等于 max_concurrency，
    第二个 run 永远停在 pending。
    """
    fake = FakeDeployer()
    first = _make_run(db_factory, fake, slug="one")
    stop = threading.Event()
    worker = threading.Thread(
        target=worker_loop,
        args=(db_factory, fake),
        kwargs={"max_concurrency": 1, "poll_interval": 0.05, "stop_event": stop},
        daemon=True,
    )
    worker.start()
    try:
        _wait_for_status(db_factory, first, "succeeded", timeout=10.0)
        second = _make_run(db_factory, fake, slug="two")
        _wait_for_status(db_factory, second, "succeeded", timeout=5.0)
        assert fake.apply_count == 2
    finally:
        stop.set()
        worker.join(timeout=5.0)
        assert not worker.is_alive()


def test_deployment_status_becomes_running_before_terraform(db_factory):
    """部署状态必须跟着 run 进入 "running"，且在 terraform 真正开跑之前就已落库。

    回归保护：若 runner 只写 run.status，父 Deployment 永远停在 "draft"，
    GET /api/deployments 就无法渲染任何生命周期状态。
    """
    probe_run = _make_run(db_factory, FakeDeployer())
    dep_id = _deployment_id_for_run(db_factory, probe_run)
    assert _deployment_status(db_factory, probe_run) == "draft"

    probe = _StatusProbeDeployer(db_factory, dep_id)
    execute_run(probe_run, probe, db_factory)
    assert probe.observed == ["running"], probe.observed


def test_deployment_status_succeeded_after_create(db_factory):
    fake = FakeDeployer()
    run_id = _make_run(db_factory, fake)
    execute_run(run_id, fake, db_factory)
    assert _get_run(db_factory, run_id).status == "succeeded"
    assert _deployment_status(db_factory, run_id) == "succeeded"


def test_deployment_status_failed_on_deployer_error(db_factory):
    fake = FakeDeployer(fail_on="apply")
    run_id = _make_run(db_factory, fake)
    execute_run(run_id, fake, db_factory)
    assert _get_run(db_factory, run_id).status == "failed"
    assert _deployment_status(db_factory, run_id) == "failed"


def test_deployment_status_failed_on_unexpected_error(db_factory):
    """非 DeployerError 路径同样要把父部署推进到 failed（两条失败路径都要覆盖）。"""
    fake = FakeDeployer(raise_on="apply")
    run_id = _make_run(db_factory, fake)
    execute_run(run_id, fake, db_factory)
    assert _get_run(db_factory, run_id).status == "failed"
    assert _deployment_status(db_factory, run_id) == "failed"


def test_deployment_status_destroyed_after_destroy(db_factory):
    """destroy 成功后部署必须落到 "destroyed"。

    若沿用 "succeeded"，破坏掉的部署看起来仍是"有活的基础设施"的成功部署：
    前端会显示成部署成功，且 destroy 的准入校验（要求 status == "succeeded"）
    会放行第二次销毁。
    """
    fake = FakeDeployer()
    create_run = _make_run(db_factory, fake)
    execute_run(create_run, fake, db_factory)
    assert _deployment_status(db_factory, create_run) == "succeeded"

    dep_id = _deployment_id_for_run(db_factory, create_run)
    destroy_run = _add_run(db_factory, dep_id, "destroy")
    execute_run(destroy_run, fake, db_factory)

    assert _get_run(db_factory, destroy_run).status == "succeeded"
    assert _deployment_status(db_factory, destroy_run) == "destroyed"


def test_worker_loop_survives_a_broken_session_factory():
    """回归保护：循环体内的瞬态错误不能把分发永久打死（原实现会直接冒出循环）。"""
    attempts = []

    def broken_factory():
        attempts.append(1)
        raise RuntimeError("database is locked")

    stop = threading.Event()
    worker = threading.Thread(
        target=worker_loop,
        args=(broken_factory, FakeDeployer()),
        kwargs={"poll_interval": 0.01, "stop_event": stop},
        daemon=True,
    )
    worker.start()
    try:
        deadline = time.monotonic() + 5.0
        while len(attempts) < 3 and time.monotonic() < deadline:
            time.sleep(0.01)
        assert len(attempts) >= 3, f"worker stopped after {len(attempts)} attempt(s)"
        assert worker.is_alive()
    finally:
        stop.set()
        worker.join(timeout=5.0)
