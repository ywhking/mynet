import os
import tempfile

# `Settings` is constructed (and lru_cached) while `app.*` is imported, and
# `create_app()`'s startup now refuses to run with the built-in JWT default or a
# placeholder netbird address. These stand in for the portal/backend/.env the
# runbook documents, and must be set before `app` is imported. `setdefault` so an
# explicit value from the shell still wins.
os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-for-pytest")
os.environ.setdefault("NETBIRD_LETSENCRYPT_EMAIL", "ops@mynet.vip")

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402

from app.db import Base, get_db  # noqa: E402
from app.main import create_app  # noqa: E402


@pytest.fixture
def client():
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    test_engine = create_engine(f"sqlite:///{path}", connect_args={"check_same_thread": False})
    TestingSession = sessionmaker(bind=test_engine, autoflush=False, autocommit=False)
    Base.metadata.create_all(bind=test_engine)

    app = create_app()

    def override_get_db():
        db = TestingSession()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    os.unlink(path)


@pytest.fixture
def db_factory(tmp_path):
    test_engine = create_engine(
        f"sqlite:///{tmp_path}/test.db", connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(bind=test_engine)
    return sessionmaker(bind=test_engine, autoflush=False, autocommit=False)
