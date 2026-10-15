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
    out = d.terraform_apply("/tmp/x.tfvars", "/tmp", {})
    assert "applied" in out
    assert "/tmp/x.tfvars" in out


def test_terraform_apply_nonzero_exit_raises(tmp_path):
    fake = tmp_path / "terraform"
    _write_exec(str(fake), "#!/bin/sh\necho boom >&2\nexit 1\n")
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo")
    with pytest.raises(DeployerError):
        d.terraform_apply("/tmp/x.tfvars", "/tmp", {})


def test_run_ansible_passes_playbook(tmp_path):
    fake = tmp_path / "ansible-playbook"
    _write_exec(str(fake), "#!/bin/sh\necho playbook=$1\nexit 0\n")
    d = RealDeployer(terraform_bin="/bin/echo", ansible_bin=str(fake))
    out = d.run_ansible("setup-docker.yml", "/tmp", {})
    assert "playbook=setup-docker.yml" in out


def test_terraform_missing_binary_raises_deployer_error():
    d = RealDeployer(terraform_bin="/nonexistent/terraform-nope", ansible_bin="/bin/echo")
    with pytest.raises(DeployerError):
        d.terraform_apply("/tmp/x.tfvars", "/tmp", {})


def test_terraform_apply_includes_init(tmp_path):
    cmdfile = tmp_path / "cmds.txt"
    fake = tmp_path / "terraform"
    _write_exec(str(fake), '#!/bin/sh\necho "$@" >> "$CMDFILE"\nexit 0\n')
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo")
    d.terraform_apply("/tmp/x.tfvars", "/tmp", {"CMDFILE": str(cmdfile)})
    recorded = cmdfile.read_text().splitlines()
    assert recorded[0].startswith("init")
    assert any(line.startswith("apply") for line in recorded)
    # No `workspace select`: each tenant has its own working directory, so the
    # shared .terraform/environment (which would swallow the operator's own
    # apply) must never be touched.
    assert not any(line.startswith("workspace") for line in recorded), recorded


def test_terraform_destroy_includes_init(tmp_path):
    cmdfile = tmp_path / "cmds.txt"
    fake = tmp_path / "terraform"
    _write_exec(str(fake), '#!/bin/sh\necho "$@" >> "$CMDFILE"\nexit 0\n')
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo")
    d.terraform_destroy("/tmp/x.tfvars", "/tmp", {"CMDFILE": str(cmdfile)})
    recorded = cmdfile.read_text().splitlines()
    assert recorded[0].startswith("init")
    assert any(line.startswith("destroy") for line in recorded)
    assert not any(line.startswith("workspace") for line in recorded), recorded


def test_generate_inventory_runs_script_with_write(tmp_path):
    outfile = tmp_path / "out.txt"
    script = tmp_path / "generate_inventory.sh"
    script.write_text(f'#!/bin/sh\necho "$@" > "{outfile}"\n')
    d = RealDeployer()
    d.generate_inventory(str(script), "/tmp", {})
    assert outfile.read_text().strip() == "--write"


def test_generate_inventory_resolves_relative_script_independently_of_cwd(tmp_path, monkeypatch):
    """`Settings.inventory_script` is relative to the ansible dir, i.e. to the `cwd` we pass.

    The script has to run although the process cwd is elsewhere — and although `cwd`
    is itself relative, which a plain ``os.path.join`` does not cover: bash would
    re-resolve the still-relative joined path against the child's cwd and fail.
    """
    ansible_dir = tmp_path / "sub" / "ansible"
    (ansible_dir / "inventory").mkdir(parents=True)
    marker = tmp_path / "ran.txt"
    (ansible_dir / "inventory" / "generate_inventory.sh").write_text(
        f'#!/bin/sh\necho "$@" > "{marker}"\n'
    )
    monkeypatch.chdir(tmp_path)  # neither ansible_dir nor its parent

    d = RealDeployer()
    d.generate_inventory("inventory/generate_inventory.sh", "sub/ansible", {})

    assert marker.read_text().strip() == "--write"


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


def test_timeout_raises_deployer_error_with_partial_output(tmp_path):
    fake = tmp_path / "terraform"
    _write_exec(str(fake), "#!/bin/sh\necho partial-output\nexec sleep 30\n")
    d = RealDeployer(terraform_bin=str(fake), ansible_bin="/bin/echo", timeout=1)
    with pytest.raises(DeployerError) as ei:
        d.terraform_apply("/tmp/x.tfvars", str(tmp_path), {})
    assert "timed out" in str(ei.value)
    assert isinstance(ei.value.output, str)
    assert "partial-output" in ei.value.output


# --- prepare_workdir: per-tenant isolation -------------------------------

def _make_module(root):
    """A stand-in for terraform/: HCL files, scripts/, plus the things that must
    NOT be copied (operator tfvars, generated keys, state)."""
    (root / "scripts").mkdir(parents=True)
    (root / "keys").mkdir()
    (root / "main.tf").write_text("variable \"alicloud_region\" {}\n")
    (root / "ecs.tf").write_text("locals { all_instances = {} }\n")
    (root / "terraform.tfvars").write_text('ecs_ssh_public_key = "OPERATOR-KEY"\n')
    (root / "terraform.tfstate").write_text('{"resources": []}\n')
    (root / "keys" / "KEY-bastion").write_text("OPERATOR-PRIVATE-KEY")
    script = root / "scripts" / "generate_key.sh"
    script.write_text("#!/bin/sh\necho '{\"public_key\":\"x\"}'\n")
    os.chmod(script, 0o755)
    return root


def test_prepare_workdir_copies_module_and_scripts(tmp_path):
    src = _make_module(tmp_path / "terraform")
    d = RealDeployer()
    workdir = d.prepare_workdir(str(src), str(tmp_path / "tenants"), "acme")

    assert workdir == str(tmp_path / "tenants" / "acme")
    assert (tmp_path / "tenants" / "acme" / "main.tf").exists()
    assert (tmp_path / "tenants" / "acme" / "ecs.tf").exists()
    script = tmp_path / "tenants" / "acme" / "scripts" / "generate_key.sh"
    assert script.exists()
    # copy2 must preserve the executable bit or terraform's data.external fails.
    assert os.access(script, os.X_OK)


def test_prepare_workdir_does_not_copy_operator_tfvars_state_or_keys(tmp_path):
    """The three leaks this function exists to close."""
    src = _make_module(tmp_path / "terraform")
    d = RealDeployer()
    workdir = tmp_path / "tenants" / "acme"
    d.prepare_workdir(str(src), str(tmp_path / "tenants"), "acme")

    # 1) the operator's terraform.tfvars must not be auto-loaded by terraform
    assert not (workdir / "terraform.tfvars").exists()
    # 2) no shared key material, and no state
    assert not (workdir / "keys").exists()
    assert not (workdir / "terraform.tfstate").exists()
    assert "OPERATOR-KEY" not in "".join(
        p.read_text() for p in workdir.rglob("*") if p.is_file()
    )


def test_prepare_workdir_is_isolated_per_tenant(tmp_path):
    """Two tenants must get two different directories, each with its own keys/."""
    src = _make_module(tmp_path / "terraform")
    d = RealDeployer()
    a = d.prepare_workdir(str(src), str(tmp_path / "tenants"), "tenant-a")
    b = d.prepare_workdir(str(src), str(tmp_path / "tenants"), "tenant-b")

    assert a != b
    script_a = os.path.join(a, "scripts", "generate_key.sh")
    script_b = os.path.join(b, "scripts", "generate_key.sh")
    assert os.path.exists(script_a) and os.path.exists(script_b)
    # `path.module/keys` resolves next to each copy, so the generated key pairs
    # are physically separate — that is what stops tenant B from receiving
    # tenant A's public key.
    assert os.path.realpath(os.path.dirname(script_a)) != os.path.realpath(os.path.dirname(script_b))


def test_prepare_workdir_recopies_when_source_is_newer(tmp_path):
    src = _make_module(tmp_path / "terraform")
    d = RealDeployer()
    workdir = tmp_path / "tenants" / "acme"
    d.prepare_workdir(str(src), str(tmp_path / "tenants"), "acme")
    assert (workdir / "main.tf").read_text().startswith("variable")

    # Make the source strictly newer than the copy.
    newer = (workdir / "main.tf").stat().st_mtime + 10
    (src / "main.tf").write_text("variable \"alicloud_region\" { default = \"cn\" }\n")
    os.utime(src / "main.tf", (newer, newer))

    d.prepare_workdir(str(src), str(tmp_path / "tenants"), "acme")
    assert "default" in (workdir / "main.tf").read_text()


def test_prepare_workdir_leaves_newer_copy_alone(tmp_path):
    src = _make_module(tmp_path / "terraform")
    d = RealDeployer()
    workdir = tmp_path / "tenants" / "acme"
    d.prepare_workdir(str(src), str(tmp_path / "tenants"), "acme")

    # A file that exists only in the tenant dir (e.g. nothing the module owns)
    # must survive a re-run, and an up-to-date copy must not be rewritten.
    stamp = (workdir / "main.tf").stat().st_mtime
    marker = workdir / "tenant-local.txt"
    marker.write_text("keep me")

    d.prepare_workdir(str(src), str(tmp_path / "tenants"), "acme")
    assert marker.read_text() == "keep me"
    assert (workdir / "main.tf").stat().st_mtime == stamp
