import threading
import time

import pytest

from app.config import Settings, get_settings
from app.deployer import DeployerError
from app.models import Deployment, Run, Tenant
from app.runner import (
    ORPHAN_ERROR,
    PLAYBOOKS,
    _demote_orphaned_runs,
    execute_run,
    worker_loop,
)

NETBIRD = "playbooks/setup-netbird.yml"
NETBIRD_AGENT = "playbooks/setup-netbird-agent.yml"
DOCKER = "playbooks/setup-docker.yml"
NETWORK = "playbooks/setup-network.yml"


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
        self.workdirs: list[str] = []

    def prepare_workdir(self, source_dir, tenants_dir, slug):
        self.calls.append("prepare_workdir")
        path = f"{tenants_dir}/{slug}"
        self.workdirs.append(path)
        return path

    def terraform_apply(self, var_file, cwd, env):
        self.calls.append("apply")
        self.apply_count += 1
        # The cwd the runner chose is load-bearing: it must be the per-tenant
        # directory, never the shared terraform_dir.
        assert cwd == self.workdirs[-1], (cwd, self.workdirs)
        if self.fail_on == "apply":
            raise DeployerError("apply failed", "boom")
        if self.raise_on == "apply":
            raise RuntimeError("kaboom")
        return "applied"

    def terraform_destroy(self, var_file, cwd, env):
        self.calls.append("destroy")
        assert cwd == self.workdirs[-1], (cwd, self.workdirs)
        return "destroyed"

    def generate_inventory(self, script_path, cwd, env, terraform_dir=None):
        self.calls.append("inventory")
        self.inventory_terraform_dir = terraform_dir
        return "inventory written"

    def run_ansible(self, playbook, cwd, env, extra_args=None):
        self.calls.append(playbook)
        self.ansible_calls.append((playbook, list(extra_args or [])))
        return f"ran {playbook}"


def _make_run(db_factory, deployer, run_type="create", slug="acme"):
    db = db_factory()
    t = Tenant(name=slug, slug=slug)
    db.add(t); db.commit()
    d = Deployment(tenant_id=t.id, subdomain=slug, config={
        "subdomain": slug,
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

    def terraform_apply(self, var_file, cwd, env):
        db = self._session_factory()
        try:
            self.observed.append(db.query(Deployment).get(self._dep_id).status)
        finally:
            db.close()
        return super().terraform_apply(var_file, cwd, env)


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

    # inventory 必须针对本租户的工作目录生成：脚本默认按自身位置推导 terraform
    # 目录（共享的 terraform/），不传就会读到平台自己的 state 与私钥。
    assert fake.inventory_terraform_dir == fake.workdirs[-1]

    # netbird 的 extra vars 只挂在 setup-netbird.yml 上（不是 setup-netbird-agent.yml）。
    # email 取自 Settings（测试 env 里设置的真实地址），不是硬编码的 example.com
    # 占位符——那个值会被 playbook 的 assert 直接拒绝。domain 由 bastion 推导，
    # 且必须带上租户子域名（见 test_netbird_domain_includes_the_tenant_subdomain）。
    s = get_settings()
    assert _extra_args_for(fake, NETBIRD) == [
        "-e",
        f"netbird_domain=bastion.acme.{s.platform_domain}",
        "-e",
        f"netbird_letsencrypt_email={s.netbird_letsencrypt_email}",
    ]
    assert _extra_args_for(fake, NETBIRD_AGENT) == [
        "-e",
        f"netbird_management_url=https://bastion.acme.{s.platform_domain}",
    ]
    assert _extra_args_for(fake, NETWORK) == []
    assert _extra_args_for(fake, DOCKER) == []

    # 每个 tenant 都在自己的目录里跑 terraform（共享目录会串 key / state / tfvars）
    assert fake.workdirs == [f"{s.tenants_dir}/acme"], fake.workdirs
    assert fake.calls.index("prepare_workdir") < fake.calls.index("apply")


def test_terraform_runs_in_the_tenant_workdir(db_factory):
    """`settings.terraform_dir` is only the source; terraform's cwd is per-tenant."""
    s = get_settings()
    fake = FakeDeployer()
    run_id = _make_run(db_factory, fake, slug="tenant-x")
    execute_run(run_id, fake, db_factory)
    # FakeDeployer.terraform_apply asserts cwd == the last prepared workdir, so
    # this also proves the runner never passes terraform_dir as cwd.
    assert fake.workdirs == [f"{s.tenants_dir}/tenant-x"]
    assert s.terraform_dir != fake.workdirs[0]


def test_destroy_also_uses_the_tenant_workdir(db_factory):
    fake = FakeDeployer()
    run_id = _make_run(db_factory, fake, run_type="destroy", slug="gone")
    execute_run(run_id, fake, db_factory)
    assert fake.workdirs == [f"{get_settings().tenants_dir}/gone"]


# --- playbook inputs the runner forwards (E) -----------------------------

_PLAYBOOK_SETTINGS = Settings(
    netbird_letsencrypt_email="ops@mynet.vip",
    platform_domain="mynet.vip",
    netbird_package="/opt/netbird-install.tar.gz",
    netbird_binary="/opt/netbird/netbird",
    docker_repo_base="https://mirrors.aliyun.com/docker-ce/linux/ubuntu",
    docker_mirrors="https://docker.m.daocloud.io",
)


def _run_with_settings(db_factory, monkeypatch, settings):
    monkeypatch.setattr("app.runner.get_settings", lambda: settings)
    fake = FakeDeployer()
    run_id = _make_run(db_factory, fake)
    execute_run(run_id, fake, db_factory)
    return fake


def test_playbook_inputs_go_to_the_right_playbook_only(db_factory, monkeypatch):
    """The playbooks default to absolute paths on the author's workstation, so
    the runner must forward the configured values — to that playbook and no
    other (a leaked `-e` overrides an unrelated playbook's variable)."""
    fake = _run_with_settings(db_factory, monkeypatch, _PLAYBOOK_SETTINGS)

    assert _extra_args_for(fake, NETBIRD) == [
        "-e",
        "netbird_package=/opt/netbird-install.tar.gz",
        "-e",
        "netbird_domain=bastion.acme.mynet.vip",
        "-e",
        "netbird_letsencrypt_email=ops@mynet.vip",
    ]
    assert _extra_args_for(fake, NETBIRD_AGENT) == [
        "-e",
        "netbird_binary=/opt/netbird/netbird",
        "-e",
        "netbird_management_url=https://bastion.acme.mynet.vip",
    ]
    assert _extra_args_for(fake, DOCKER) == [
        "-e",
        "docker_repo_base=https://mirrors.aliyun.com/docker-ce/linux/ubuntu",
        "-e",
        "docker_mirrors=https://docker.m.daocloud.io",
    ]
    assert _extra_args_for(fake, NETWORK) == []


def test_netbird_domain_includes_the_tenant_subdomain(db_factory, monkeypatch):
    """回归保护：bastion 的 FQDN 必须包含租户子域名。

    `tfvars.py` 把 terraform 的 `domain_name`（DNS zone）写成
    `"<subdomain>.<platform_domain>"`，`terraform/dns.tf` 再在其中以
    `rr = <实例 domain_name>` 建 A 记录，所以 bastion 实际解析在
    `bastion.<subdomain>.<platform_domain>`。写成 `bastion.<platform_domain>`
    会指向一个没有 A 记录的名字，并且让所有租户的 bastion 抢同一个主机名。
    """
    settings = Settings(netbird_letsencrypt_email="ops@mynet.vip", platform_domain="mynet.vip")
    fake = _run_with_settings(db_factory, monkeypatch, settings)

    assert _extra_args_for(fake, NETBIRD) == [
        "-e",
        "netbird_domain=bastion.acme.mynet.vip",
        "-e",
        "netbird_letsencrypt_email=ops@mynet.vip",
    ]
    assert _extra_args_for(fake, NETBIRD_AGENT) == [
        "-e",
        "netbird_management_url=https://bastion.acme.mynet.vip",
    ]


def test_optional_playbook_inputs_absent_when_unset(db_factory, monkeypatch):
    """Unset optional inputs must not be forwarded, so the playbook's own default
    stays in force. Only the deployment-derived netbird domain/URL and the
    required email are always sent."""
    s = Settings(netbird_letsencrypt_email="ops@mynet.vip", platform_domain="mynet.vip")
    fake = _run_with_settings(db_factory, monkeypatch, s)

    assert _extra_args_for(fake, NETBIRD) == [
        "-e",
        "netbird_domain=bastion.acme.mynet.vip",
        "-e",
        "netbird_letsencrypt_email=ops@mynet.vip",
    ]
    assert _extra_args_for(fake, NETBIRD_AGENT) == [
        "-e",
        "netbird_management_url=https://bastion.acme.mynet.vip",
    ]
    assert _extra_args_for(fake, DOCKER) == []


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


# --- orphaned `running` runs (G) -----------------------------------------

def _orphan_run(db_factory, run_id):
    """Simulate the worker dying mid-run: the row is left at `running`."""
    db = db_factory()
    r = db.query(Run).get(run_id)
    r.status = "running"
    r.log = "==> terraform apply\n"
    dep = db.query(Deployment).get(r.deployment_id)
    dep.status = "running"
    db.commit()
    db.close()


def test_demote_orphaned_runs_marks_them_failed(db_factory):
    run_id = _make_run(db_factory, FakeDeployer())
    _orphan_run(db_factory, run_id)

    assert _demote_orphaned_runs(db_factory) == 1

    r = _get_run(db_factory, run_id)
    assert r.status == "failed"
    assert r.error == ORPHAN_ERROR
    assert r.finished_at is not None
    # The original output must be kept — it is the only clue about how far the
    # dead run got — and the recovery must be explained.
    assert "terraform apply" in r.log
    assert "recovered on worker startup" in r.log
    assert _deployment_status(db_factory, run_id) == "failed"


def test_demote_orphaned_runs_leaves_other_statuses_alone(db_factory):
    deployer = FakeDeployer()
    done = _make_run(db_factory, deployer, slug="done")
    execute_run(done, deployer, db_factory)  # succeeded
    pending = _make_run(db_factory, deployer, slug="waiting")  # still pending

    assert _demote_orphaned_runs(db_factory) == 0
    assert _get_run(db_factory, done).status == "succeeded"
    assert _get_run(db_factory, pending).status == "pending"


def test_worker_loop_demotes_orphans_at_startup(db_factory):
    """Without this, a dead worker leaves a `running` row that no code path
    revisits: worker_loop only polls `pending`, destroy refuses while a create is
    in flight, and create is blocked by the running-count quota."""
    fake = FakeDeployer()
    run_id = _make_run(db_factory, fake)
    _orphan_run(db_factory, run_id)

    stop = threading.Event()
    worker = threading.Thread(
        target=worker_loop,
        args=(db_factory, fake),
        kwargs={"max_concurrency": 1, "poll_interval": 0.05, "stop_event": stop},
        daemon=True,
    )
    worker.start()
    try:
        _wait_for_status(db_factory, run_id, "failed", timeout=10.0)
        assert fake.calls == [], "an orphaned run must never be executed"
        # And the tenant is unblocked: a fresh create run is picked up.
        retry = _add_run(db_factory, _deployment_id_for_run(db_factory, run_id), "create")
        _wait_for_status(db_factory, retry, "succeeded", timeout=5.0)
    finally:
        stop.set()
        worker.join(timeout=5.0)
        assert not worker.is_alive()


def test_worker_loop_refuses_to_start_with_invalid_settings(db_factory, monkeypatch):
    """The netbird email is required by the playbook's assert, so a worker without
    one would fail every deploy after terraform already spent money."""
    monkeypatch.setattr(
        "app.runner.get_settings",
        lambda: Settings(jwt_secret_key="real-secret", netbird_letsencrypt_email=""),
    )
    with pytest.raises(RuntimeError):
        worker_loop(db_factory, FakeDeployer(), stop_event=threading.Event())
