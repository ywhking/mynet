from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Protocol


class DeployerError(Exception):
    def __init__(self, message: str, output: str = ""):
        super().__init__(message)
        self.output = output


class Deployer(Protocol):
    # prepare_workdir returns the cwd terraform must run in for this tenant.
    def prepare_workdir(self, source_dir: str, tenants_dir: str, slug: str) -> str: ...
    def terraform_apply(self, var_file: str, cwd: str, env: dict[str, str]) -> str: ...
    def terraform_destroy(self, var_file: str, cwd: str, env: dict[str, str]) -> str: ...
    def generate_inventory(
        self,
        script_path: str,
        cwd: str,
        env: dict[str, str],
        terraform_dir: str | None = None,
        out_path: str | None = None,
    ) -> str: ...
    def run_ansible(
        self,
        playbook: str,
        cwd: str,
        env: dict[str, str],
        extra_args: list[str] | None = None,
        inventory_path: str | None = None,
    ) -> str: ...


def _copy_if_newer(src: Path, dst: Path) -> bool:
    """Copy ``src`` over ``dst`` unless ``dst`` is already at least as new.

    mtime is the only signal available without hashing the whole tree, and the
    module files are edited by hand, so "source is newer" is both cheap and
    accurate enough.
    """
    try:
        if dst.exists() and dst.stat().st_mtime >= src.stat().st_mtime:
            return False
    except OSError:
        pass
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)  # copy2 keeps the executable bit on the scripts
    return True


class RealDeployer:
    def __init__(
        self,
        terraform_bin: str = "terraform",
        ansible_bin: str = "ansible-playbook",
        timeout: int = 3600,
    ):
        self.terraform_bin = terraform_bin
        self.ansible_bin = ansible_bin
        self.timeout = timeout

    def _run(self, cmd: list[str], cwd: str, env: dict[str, str]) -> str:
        merged = {**os.environ, **env}
        try:
            proc = subprocess.run(
                cmd, cwd=cwd, env=merged, capture_output=True, text=True, timeout=self.timeout
            )
        except subprocess.TimeoutExpired as e:
            def _text(v) -> str:
                if v is None:
                    return ""
                return v.decode("utf-8", "replace") if isinstance(v, bytes) else v

            raise DeployerError(
                f"command timed out: {' '.join(cmd)}",
                _text(e.stdout) + _text(e.stderr),
            ) from e
        except OSError as e:
            raise DeployerError(f"failed to start command: {' '.join(cmd)}: {e}") from e
        out = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode != 0:
            raise DeployerError(f"command failed: {' '.join(cmd)}", out)
        return out

    def prepare_workdir(self, source_dir: str, tenants_dir: str, slug: str) -> str:
        """Materialise an isolated terraform working directory for one tenant.

        Sharing `settings.terraform_dir` across tenants leaks in three ways:
          * `scripts/generate_key.sh` writes to `../keys` relative to the module,
            so every tenant collides in one `keys/` directory and the *first*
            tenant's public key is handed to the second (whose private key is
            then authorised to root-login them);
          * Terraform auto-loads any `terraform.tfvars` sitting in the working
            directory, so the operator's own (e.g. `ecs_ssh_public_key`) is
            silently injected into every tenant apply;
          * `terraform workspace select` writes the shared
            `.terraform/environment`, so the operator's later manual apply lands
            in whichever tenant ran last.

        Giving each tenant its own copy of `*.tf` + `scripts/` fixes all three:
        `path.module/keys/` and the state file are per-tenant, and the working
        directory contains no `terraform.tfvars`. With per-tenant state
        directories the workspace indirection is redundant, so terraform runs in
        the default workspace.
        """
        src = Path(source_dir)
        dst = Path(tenants_dir) / slug
        dst.mkdir(parents=True, exist_ok=True)

        # Only the HCL module and its scripts. Deliberately not `*.tfvars`,
        # `keys/`, `*.tfstate*` or `.terraform/`: copying the operator's tfvars
        # would reintroduce exactly the leak this function exists to close.
        for tf in sorted(src.glob("*.tf")):
            _copy_if_newer(tf, dst / tf.name)

        scripts_src = src / "scripts"
        if scripts_src.is_dir():
            for path in sorted(scripts_src.rglob("*")):
                if path.is_file():
                    _copy_if_newer(path, dst / "scripts" / path.relative_to(scripts_src))
        return str(dst)

    def terraform_apply(self, var_file: str, cwd: str, env: dict[str, str]) -> str:
        return self._run(
            [self.terraform_bin, "init", "-input=false"],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "apply", "-auto-approve", f"-var-file={var_file}"],
            cwd, env,
        )

    def terraform_destroy(self, var_file: str, cwd: str, env: dict[str, str]) -> str:
        return self._run(
            [self.terraform_bin, "init", "-input=false"],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "destroy", "-auto-approve", f"-var-file={var_file}"],
            cwd, env,
        )

    def generate_inventory(
        self,
        script_path: str,
        cwd: str,
        env: dict[str, str],
        terraform_dir: str | None = None,
        out_path: str | None = None,
    ) -> str:
        # bash resolves a relative script argument against the *child's* cwd, which
        # subprocess sets to `cwd`. Passing a cwd-relative script_path straight through
        # would therefore have it re-resolved against `cwd` a second time
        # (cwd/cwd/script) — the doubled path of the original bug. Resolve to an
        # absolute path so the child's cwd cannot influence it at all: a plain join is
        # not enough, because with a relative `cwd` (e.g. "../../terraform/ansible")
        # the joined path is still relative and gets re-resolved the same way.
        path = script_path if os.path.isabs(script_path) else os.path.abspath(os.path.join(cwd, script_path))
        cmd = ["bash", path, "--write"]
        if out_path:
            # Without this the script writes into its own directory
            # (`ansible/inventory/hosts.yml`) — one global file shared by every
            # tenant. Absolute for the same child-cwd reason as `path` above.
            cmd.append(os.path.abspath(out_path))
        if terraform_dir:
            # The script otherwise derives its terraform directory from its own
            # location (always the shared `terraform/`), so a tenant run would read
            # the platform's state and private keys instead of its own. The flag
            # must be absolute for the same child-cwd reason as `path` above.
            cmd += ["--terraform-dir", os.path.abspath(terraform_dir)]
        return self._run(cmd, cwd, env)

    def run_ansible(
        self,
        playbook: str,
        cwd: str,
        env: dict[str, str],
        extra_args: list[str] | None = None,
        inventory_path: str | None = None,
    ) -> str:
        cmd = [self.ansible_bin]
        if inventory_path:
            # `-i` REPLACES the `inventory` setting in ansible.cfg (it does not
            # merge), which is what makes each tenant's run read its own file
            # instead of the shared `ansible/inventory/hosts.yml`.
            cmd += ["-i", os.path.abspath(inventory_path)]
        cmd += [playbook, *(extra_args or [])]
        return self._run(cmd, cwd, env)
