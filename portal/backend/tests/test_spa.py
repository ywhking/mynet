"""The built SPA is served by the API process.

The frontend calls `/api/...` with relative paths (`src/api.ts`), the router is
a `<BrowserRouter>`, and `create_app` configures no CORS — so the bundle and the
API must share one origin. Serving `dist/` from FastAPI is what makes the
deployment a single upstream behind the existing Caddy.
"""

import pytest

from app import main as app_main


@pytest.fixture
def dist(tmp_path, monkeypatch):
    """A stand-in for `npm run build` output, wired into the app."""
    root = tmp_path / "dist"
    (root / "assets").mkdir(parents=True)
    (root / "index.html").write_text('<!doctype html><div id="root"></div>')
    (root / "assets" / "app.js").write_text("console.log('bundle')")
    monkeypatch.setattr(app_main, "_spa_root", lambda: root)
    return root


def test_index_is_served_at_the_root(client, dist):
    r = client.get("/")
    assert r.status_code == 200
    assert 'id="root"' in r.text


def test_deep_links_fall_back_to_index(client, dist):
    """`/login`, `/deployments/1` are client-side routes.

    They are only requested on a hard refresh or a direct link, which is why
    this breaks silently in a dev flow that only ever navigates in-app.
    """
    for path in ("/login", "/register", "/deployments/1"):
        r = client.get(path)
        assert r.status_code == 200, path
        assert 'id="root"' in r.text, path


def test_a_real_asset_is_served_instead_of_index(client, dist):
    r = client.get("/assets/app.js")
    assert r.status_code == 200
    assert "console.log('bundle')" in r.text


def test_unknown_api_paths_still_404(client, dist):
    """The catch-all must not swallow API 404s.

    Otherwise `fetch('/api/typo')` gets HTML with a 200 and the caller fails
    somewhere far away, parsing JSON.
    """
    assert client.get("/api/nope").status_code == 404
    assert client.get("/api").status_code == 404


def test_api_health_is_unaffected(client, dist):
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_a_symlink_escaping_the_bundle_is_not_served(client, dist, tmp_path):
    """Containment guard: only files really inside the bundle may be returned."""
    secret = tmp_path / "secret.txt"
    secret.write_text("TOP SECRET")
    (dist / "leak.txt").symlink_to(secret)

    r = client.get("/leak.txt")

    assert "TOP SECRET" not in r.text


def test_a_missing_bundle_fails_loudly_rather_than_500ing(client, tmp_path, monkeypatch):
    """Running without `npm run build` should say so, not crash."""
    monkeypatch.setattr(app_main, "_spa_root", lambda: tmp_path / "never-built")

    r = client.get("/")

    assert r.status_code == 404
    assert "not built" in r.json()["detail"].lower()
