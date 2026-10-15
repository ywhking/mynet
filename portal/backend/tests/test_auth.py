def test_register_creates_tenant_and_returns_token(client):
    r = client.post("/api/auth/register", json={
        "tenant_name": "Acme Corp",
        "email": "admin@acme.com",
        "password": "s3cret123",
    })
    assert r.status_code == 200
    assert "access_token" in r.json()


def test_register_duplicate_email_conflict(client):
    body = {"tenant_name": "Acme", "email": "dup@acme.com", "password": "s3cret123"}
    assert client.post("/api/auth/register", json=body).status_code == 200
    r = client.post("/api/auth/register", json=body)
    assert r.status_code == 409


def test_login_roundtrip(client):
    client.post("/api/auth/register", json={
        "tenant_name": "Acme", "email": "login@acme.com", "password": "s3cret123",
    })
    r = client.post("/api/auth/login", json={"email": "login@acme.com", "password": "s3cret123"})
    assert r.status_code == 200
    assert "access_token" in r.json()

    bad = client.post("/api/auth/login", json={"email": "login@acme.com", "password": "wrong"})
    assert bad.status_code == 401
