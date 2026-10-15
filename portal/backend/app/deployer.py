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
    def run_ansible(self, playbook: str, cwd: str, env: dict[str, str]) -> str: ...


class RealDeployer:
    def __init__(self, terraform_bin: str = "terraform", ansible_bin: str = "ansible-playbook"):
        self.terraform_bin = terraform_bin
        self.ansible_bin = ansible_bin

    def _run(self, cmd: list[str], cwd: str, env: dict[str, str]) -> str:
        import os

        merged = {**os.environ, **env}
        proc = subprocess.run(cmd, cwd=cwd, env=merged, capture_output=True, text=True, timeout=3600)
        out = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode != 0:
            raise DeployerError(f"command failed: {' '.join(cmd)}", out)
        return out

    def terraform_apply(self, workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str:
        return self._run(
            [self.terraform_bin, "workspace", "select", "-or-create", workspace],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "apply", "-auto-approve", f"-var-file={var_file}"],
            cwd, env,
        )

    def terraform_destroy(self, workspace: str, var_file: str, cwd: str, env: dict[str, str]) -> str:
        return self._run(
            [self.terraform_bin, "workspace", "select", "-or-create", workspace],
            cwd, env,
        ) + self._run(
            [self.terraform_bin, "destroy", "-auto-approve", f"-var-file={var_file}"],
            cwd, env,
        )

    def run_ansible(self, playbook: str, cwd: str, env: dict[str, str]) -> str:
        return self._run([self.ansible_bin, playbook], cwd, env)
