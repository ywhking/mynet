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


def test_terraform_missing_binary_raises_deployer_error():
    d = RealDeployer(terraform_bin="/nonexistent/terraform-nope", ansible_bin="/bin/echo")
    with pytest.raises(DeployerError):
        d.terraform_apply("acme", "/tmp/x.tfvars", "/tmp", {})


def test_terraform_apply_includes_init(tmp_path):
    cmdfile = tmp_path / "cmds.txt"
    fake = tmp_path / "terraform"
    _write_exec(str(fake), '#!/bin/sh\necho "$@" >> "$CMDFILE"\nexit 0\n')
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo")
    d.terraform_apply("acme", "/tmp/x.tfvars", "/tmp", {"CMDFILE": str(cmdfile)})
    recorded = cmdfile.read_text().splitlines()
    assert recorded[0].startswith("init")
    assert any(line.startswith("workspace select") for line in recorded)


def test_terraform_destroy_includes_init(tmp_path):
    cmdfile = tmp_path / "cmds.txt"
    fake = tmp_path / "terraform"
    _write_exec(str(fake), '#!/bin/sh\necho "$@" >> "$CMDFILE"\nexit 0\n')
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo")
    d.terraform_destroy("acme", "/tmp/x.tfvars", "/tmp", {"CMDFILE": str(cmdfile)})
    recorded = cmdfile.read_text().splitlines()
    assert recorded[0].startswith("init")
    assert any(line.startswith("destroy") for line in recorded)


def test_generate_inventory_runs_script_with_write(tmp_path):
    outfile = tmp_path / "out.txt"
    script = tmp_path / "generate_inventory.sh"
    script.write_text(f'#!/bin/sh\necho "$@" > "{outfile}"\n')
    d = RealDeployer()
    d.generate_inventory(str(script), "/tmp", {})
    assert outfile.read_text().strip() == "--write"


def test_run_ansible_passes_extra_args(tmp_path):
    fake = tmp_path / "ansible-playbook"
    _write_exec(str(fake), '#!/bin/sh\necho "$@"\nexit 0\n')
    d = RealDeployer(terraform_bin="/bin/echo", ansible_bin=str(fake))
    out = d.run_ansible(
        "setup-netbird.yml",
        "/tmp",
        {},
        extra_args=["-e", "netbird_letsencrypt_email=a@b.com"],
    )
    assert "-e" in out
    assert "netbird_letsencrypt_email=a@b.com" in out


def test_run_ansible_without_extra_args(tmp_path):
    fake = tmp_path / "ansible-playbook"
    _write_exec(str(fake), '#!/bin/sh\necho "$@"\nexit 0\n')
    d = RealDeployer(terraform_bin="/bin/echo", ansible_bin=str(fake))
    out = d.run_ansible("setup-docker.yml", "/tmp", {})
    assert out.strip() == "setup-docker.yml"
    assert "-e" not in out
