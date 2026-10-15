import os
import stat
import tempfile

import pytest

from app.deployer import DeployerError, RealDeployer


def _write_exec(path: str, content: str):
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)


def test_terraform_apply_runs_binary_and_returns_output(tmp_path):
    fake = tmp_path / "terraform"
    _write_exec(str(fake), "#!/bin/sh\necho applied $@\nexit 0\n")
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo")
    out = d.terraform_apply("acme", "/tmp/x.tfvars", "/tmp", {})
    assert "applied" in out
    assert "workspace" in out  # 我们传了 workspace 参数


def test_terraform_apply_nonzero_exit_raises(tmp_path):
    fake = tmp_path / "terraform"
    _write_exec(str(fake), "#!/bin/sh\necho boom >&2\nexit 1\n")
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo")
    with pytest.raises(DeployerError):
        d.terraform_apply("acme", "/tmp/x.tfvars", "/tmp", {})


def test_run_ansible_passes_playbook(tmp_path):
    fake = tmp_path / "ansible-playbook"
    _write_exec(str(fake), "#!/bin/sh\necho playbook=$1\nexit 0\n")
    d = RealDeployer(terraform_bin="/bin/echo", ansible_bin=str(fake))
    out = d.run_ansible("setup-docker.yml", "/tmp", {})
    assert "playbook=setup-docker.yml" in out
