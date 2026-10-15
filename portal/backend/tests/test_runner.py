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

    def generate_inventory(self, script_path, cwd, env):
        self.calls.append("inventory")
        return "inventory written"

    def run_ansible(self, playbook, cwd, env, extra_args=None):
        self.calls.append(playbook)
        if extra_args:
            self.calls.append(" ".join(extra_args))
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
    joined = " ".join(fake.calls)
    assert "setup-network" in joined
    assert "inventory" in fake.calls  # generate_inventory 必须在 playbook 之前跑
    assert "netbird_letsencrypt_email=" in joined  # setup-netbird.yml 必需的 extra var
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
