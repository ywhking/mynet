from app.db import get_db
from app.models import Deployment, Run


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


def _db(client):
    """The session the app under test is using, via the conftest `get_db` override.

    Lets a test assert on rows directly (e.g. that no orphan Deployment exists)
    without reaching into the app's internals.
    """
    return next(client.app.dependency_overrides[get_db]())


def test_create_is_atomic(client):
    """Deployment 与它的 pending Run 必须一起落库。

    若 Deployment 先单独 commit、Run 的 commit 失败，会留下一个没有任何 run 的
    孤儿 Deployment：永远不会被执行，也永远停在 draft。
    """
    token = _register(client, "atomic@acme.com")
    r = client.post("/api/deployments", json=_config_body(), headers=_auth(token))
    assert r.status_code == 200
    body = r.json()

    db = _db(client)
    try:
        deployments = db.query(Deployment).all()
        runs = db.query(Run).all()
    finally:
        db.close()

    assert len(deployments) == 1
    assert len(runs) == 1, "orphan deployment: create committed without its run"
    assert runs[0].deployment_id == deployments[0].id
    assert runs[0].id == body["run_id"]
    assert runs[0].type == "create"
    assert runs[0].status == "pending"


def _set_status(client, dep_id, status):
    db = _db(client)
    try:
        db.query(Deployment).get(dep_id).status = status
        db.commit()
    finally:
        db.close()


def _destroy_runs(client, dep_id):
    db = _db(client)
    try:
        return db.query(Run).filter(Run.deployment_id == dep_id, Run.type == "destroy").all()
    finally:
        db.close()


def _create_dep(client, email):
    token = _register(client, email)
    dep_id = client.post("/api/deployments", json=_config_body(), headers=_auth(token)).json()["id"]
    return token, dep_id


def test_destroy_rejected_when_not_deployed(client):
    """从未成功创建过基础设施（status="draft"）的部署不能销毁。"""
    token, dep_id = _create_dep(client, "d1@acme.com")

    r = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert r.status_code == 400
    assert "succeeded" in r.json()["detail"]
    assert _destroy_runs(client, dep_id) == []


def test_destroy_rejected_when_destroy_already_pending(client):
    """重复 POST destroy 不能堆积 run —— 每个都会对已销毁的 state 再跑一次。"""
    token, dep_id = _create_dep(client, "d2@acme.com")
    _set_status(client, dep_id, "succeeded")

    first = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert first.status_code == 200

    second = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert second.status_code == 400
    assert len(_destroy_runs(client, dep_id)) == 1


def test_destroy_rejected_when_destroy_running(client):
    """已在执行中的 destroy run 同样要挡住重复入队（status="running" 也要覆盖）。"""
    token, dep_id = _create_dep(client, "d3@acme.com")
    _set_status(client, dep_id, "succeeded")

    assert client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token)).status_code == 200

    db = _db(client)
    try:
        db.query(Run).filter(Run.deployment_id == dep_id, Run.type == "destroy").first().status = "running"
        db.commit()
    finally:
        db.close()

    assert client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token)).status_code == 400
    assert len(_destroy_runs(client, dep_id)) == 1


def test_destroy_allowed_when_deployed(client):
    """正向路径：已成功创建的部署可以销毁（守卫不能把正常用例也挡掉）。"""
    token, dep_id = _create_dep(client, "d4@acme.com")
    _set_status(client, dep_id, "succeeded")

    r = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert r.status_code == 200
    assert r.json()["status"] == "pending"
    assert len(_destroy_runs(client, dep_id)) == 1
