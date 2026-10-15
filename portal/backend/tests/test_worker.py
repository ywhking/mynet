"""The worker is a separate process from the API.

`app.main` never starts it, so without an entry point every queued run stays
`pending` forever. The runbook used to drive it through a four-import
`python -c` one-liner; this module is that one-liner, made runnable and testable.
"""


def test_main_starts_the_worker_loop_with_the_real_dependencies(monkeypatch):
    from app import worker
    from app.db import SessionLocal
    from app.deployer import RealDeployer

    captured = {}

    def fake_worker_loop(session_factory, deployer, **kwargs):
        captured["session_factory"] = session_factory
        captured["deployer"] = deployer
        captured["kwargs"] = kwargs

    monkeypatch.setattr(worker, "worker_loop", fake_worker_loop)
    worker.main()

    assert captured["session_factory"] is SessionLocal
    assert isinstance(captured["deployer"], RealDeployer)


def test_concurrency_is_not_raised_from_the_environment(monkeypatch):
    """`worker_loop` must stay at max_concurrency=1.

    Every `ansible-playbook` and `generate_inventory.sh` runs with the shared
    `Settings.ansible_dir` as its cwd, so two concurrent runs would clobber each
    other's working directory. Guarding the entry point keeps a future
    `WORKER_MAX_CONCURRENCY=4` in the compose env from silently enabling that.
    """
    from app import worker

    captured = {}

    def fake_worker_loop(session_factory, deployer, **kwargs):
        captured.update(kwargs)

    monkeypatch.setattr(worker, "worker_loop", fake_worker_loop)
    monkeypatch.setenv("WORKER_MAX_CONCURRENCY", "4")
    worker.main()

    # Explicitly present and pinned — not merely left to the signature default,
    # which a later refactor could silently start feeding from the environment.
    assert captured["max_concurrency"] == 1
