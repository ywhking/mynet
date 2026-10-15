"""Entry point for the deployment worker process.

Run as `python -m app.worker`.

`app.main` deliberately does not start the worker — the API only accepts and
queues work. Without this process, every `Run` stays `pending` forever.
"""

from .db import SessionLocal
from .deployer import RealDeployer
from .runner import worker_loop


def main() -> None:
    # max_concurrency is passed EXPLICITLY and must stay 1, even though 1 is
    # also the signature default. Every `ansible-playbook` and
    # `generate_inventory.sh` runs with the shared `Settings.ansible_dir` as its
    # cwd, so two concurrent runs would clobber each other's working directory.
    # Spelling it out here means the number cannot be changed by an environment
    # variable that nobody re-read this comment for.
    worker_loop(SessionLocal, RealDeployer(), max_concurrency=1)


if __name__ == "__main__":
    main()
