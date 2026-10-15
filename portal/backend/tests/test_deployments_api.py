def _register(client, email, tenant="Acme"):
    r = client.post("/api/auth/register", json={"tenant_name": tenant, "email": email, "password": "s3cret123"})
    return r.json()["access_token"]


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _config_body():
    return {
        "subdomain": "acme",
        "public_devices": {
            "cidr": "172.16.0.0/24",
            "instances": {
                "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"},
            },
        },
        "internal_devices": {"cidr": "172.16.1.0/24", "instances": {"db": {"host_name": "db"}}},
    }


def test_create_deployment_returns_id(client):
    token = _register(client, "a@acme.com")
    r = client.post("/api/deployments", json=_config_body(), headers=_auth(token))
    assert r.status_code == 200
    assert r.json()["id"] > 0


def test_create_invalid_config_rejected(client):
    token = _register(client, "b@acme.com")
    body = _config_body()
    body["public_devices"]["instances"]["bastion"]["is_bastion"] = False
    r = client.post("/api/deployments", json=body, headers=_auth(token))
    assert r.status_code == 400


def test_tenant_isolation_cannot_see_others(client):
    token_a = _register(client, "a@x.com", "Tenant A")
    token_b = _register(client, "b@y.com", "Tenant B")
    r = client.post("/api/deployments", json=_config_body(), headers=_auth(token_a))
    dep_id = r.json()["id"]
    r2 = client.get(f"/api/deployments/{dep_id}", headers=_auth(token_b))
    assert r2.status_code == 404


def test_unauthenticated_rejected(client):
    assert client.get("/api/deployments").status_code == 401
