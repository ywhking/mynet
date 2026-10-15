import pytest

from app.config import (
    INSECURE_JWT_DEFAULT,
    Settings,
    get_settings,
    validate_runtime_settings,
)


def _ok(**overrides) -> Settings:
    base = {"jwt_secret_key": "a-real-secret", "netbird_letsencrypt_email": "ops@mynet.vip"}
    base.update(overrides)
    return Settings(**base)


def test_valid_settings_pass():
    validate_runtime_settings(_ok())


def test_default_jwt_secret_refused():
    """The shipped default is in this repo: anyone can forge a token for any
    email, i.e. read and destroy every tenant's deployment."""
    with pytest.raises(RuntimeError) as ei:
        validate_runtime_settings(_ok(jwt_secret_key=INSECURE_JWT_DEFAULT))
    assert "JWT_SECRET_KEY" in str(ei.value)


def test_default_jwt_secret_allowed_with_explicit_dev_flag():
    validate_runtime_settings(
        _ok(jwt_secret_key=INSECURE_JWT_DEFAULT, allow_insecure_dev_defaults=True)
    )


def test_empty_netbird_email_refused():
    with pytest.raises(RuntimeError) as ei:
        validate_runtime_settings(_ok(netbird_letsencrypt_email=""))
    assert "NETBIRD_LETSENCRYPT_EMAIL" in str(ei.value)


def test_whitespace_netbird_email_refused():
    with pytest.raises(RuntimeError):
        validate_runtime_settings(_ok(netbird_letsencrypt_email="   "))


@pytest.mark.parametrize(
    "email",
    [
        "admin@example.com",
        "admin@example.org",
        "admin@test.net",
        "admin@invalid.edu",
        "admin@EXAMPLE.com",
    ],
)
def test_placeholder_netbird_email_refused(email):
    """setup-netbird.yml asserts the address does not match @example/@test/
    @invalid, so letting it through guarantees a failed run at the netbird step —
    after terraform has already spent money."""
    with pytest.raises(RuntimeError) as ei:
        validate_runtime_settings(_ok(netbird_letsencrypt_email=email))
    assert "placeholder" in str(ei.value)


def test_guard_mirrors_the_playbook_pattern_exactly():
    """Documented quirk: the playbook's pattern is `@(example|...)`, anchored at
    the end but *not* at the start, so `admin@yourplatform.example.com` slips
    through. That is precisely why the shipped default is now empty (empty is
    rejected above) instead of relying on the pattern to catch a placeholder.
    """
    validate_runtime_settings(_ok(netbird_letsencrypt_email="admin@yourplatform.example.com"))


def test_shipped_default_email_is_empty():
    """Regression guard against ever re-pinning a placeholder default.

    Asserted on the declared default (not a constructed Settings) so the test
    does not depend on the process environment.
    """
    assert Settings.model_fields["netbird_letsencrypt_email"].default == ""


def test_dev_flag_does_not_excuse_the_placeholder_email():
    """The email is required by the playbook regardless of the dev flag."""
    with pytest.raises(RuntimeError):
        validate_runtime_settings(
            _ok(netbird_letsencrypt_email="admin@example.com", allow_insecure_dev_defaults=True)
        )


def test_app_refuses_to_start_with_an_insecure_config(monkeypatch):
    """The guard must be wired into the app's startup, not just available."""
    from fastapi.testclient import TestClient

    from app.main import create_app

    monkeypatch.setattr(
        "app.main.get_settings",
        lambda: Settings(jwt_secret_key=INSECURE_JWT_DEFAULT, netbird_letsencrypt_email="ops@mynet.vip"),
    )
    with pytest.raises(RuntimeError):
        with TestClient(create_app()):
            pass


def test_app_starts_with_the_test_env():
    from fastapi.testclient import TestClient

    from app.main import create_app

    with TestClient(create_app()) as c:
        assert c.get("/api/health").json() == {"status": "ok"}


def test_test_env_is_not_using_the_insecure_default():
    """The suite must exercise the real path (a configured secret), not the
    dev-flag bypass — otherwise the guard would be untested everywhere."""
    s = get_settings()
    assert s.jwt_secret_key != INSECURE_JWT_DEFAULT
    assert not s.allow_insecure_dev_defaults
