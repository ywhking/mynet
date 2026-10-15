from __future__ import annotations

import subprocess
from typing import Protocol


class DeployerError(Exception):
    def __init__(self, message: str, output: str = ""):
        super().__init__(message)
        self.output = output


class Deployer(Protocol):
    def terraform_apply(self, workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str: ...
    def terraform_destroy(self, workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str: ...
    def generate_inventory(self, script_path: str, cwd: str, env: dict[str, str]) -> str: ...
    def run_ansible(
        self, playbook: str, cwd: str, env: dict[str, str], extra_args: list[str] | None = None
    ) -> str: ...


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
        import os

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

    def terraform_apply(self, workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str:
        return self._run(
            [self.terraform_bin, "init", "-input=false"],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "workspace", "select", "-or-create", workspace],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "apply", "-auto-approve", f"-var-file={var_file}"],
            cwd, env,
        )

    def terraform_destroy(self, workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str:
        return self._run(
            [self.terraform_bin, "init", "-input=false"],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "workspace", "select", "-or-create", workspace],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "destroy", "-auto-approve", f"-var-file={var_file}"],
            cwd, env,
        )

    def generate_inventory(self, script_path: str, cwd: str, env: dict[str, str]) -> str:
        # bash resolves a relative script argument against the *child's* cwd, which
        # subprocess sets to `cwd`. Passing a cwd-relative script_path straight through
        # would therefore have it re-resolved against `cwd` a second time
        # (cwd/cwd/script) — the doubled path of the original bug. Resolve to an
        # absolute path so the child's cwd cannot influence it at all: a plain join is
        # not enough, because with a relative `cwd` (e.g. "../../terraform/ansible")
        # the joined path is still relative and gets re-resolved the same way.
        import os

        path = script_path if os.path.isabs(script_path) else os.path.abspath(os.path.join(cwd, script_path))
        return self._run(["bash", path, "--write"], cwd, env)

    def run_ansible(
        self, playbook: str, cwd: str, env: dict[str, str], extra_args: list[str] | None = None
    ) -> str:
        return self._run([self.ansible_bin, playbook, *(extra_args or [])], cwd, env)
