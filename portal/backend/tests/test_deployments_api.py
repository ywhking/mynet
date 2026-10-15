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


def test_second_tenant_same_subdomain_rejected(client):
    """The DNS zone is shared, so <subdomain>.<platform_domain> is one hostname.

    Registration is self-service (spec §4) with no human gate, so nothing else
    would stop two tenants from racing for the same A record.
    """
    token_a = _register(client, "a@dup.com", "Tenant A")
    token_b = _register(client, "b@dup.com", "Tenant B")

    first = client.post("/api/deployments", json=_config_body(), headers=_auth(token_a))
    assert first.status_code == 200

    second = client.post("/api/deployments", json=_config_body(), headers=_auth(token_b))
    assert second.status_code == 400, second.text
    assert "subdomain" in second.json()["detail"]
    assert "taken" in second.json()["detail"]


def test_same_tenant_same_subdomain_rejected(client):
    """Also per tenant: two deployments cannot claim one hostname."""
    token = _register(client, "same@dup.com")
    assert client.post("/api/deployments", json=_config_body(), headers=_auth(token)).status_code == 200
    again = client.post("/api/deployments", json=_config_body(), headers=_auth(token))
    assert again.status_code == 400


def test_different_subdomains_both_accepted(client):
    """The uniqueness check must not block the normal path."""
    token_a = _register(client, "a@ok.com", "Tenant A")
    token_b = _register(client, "b@ok.com", "Tenant B")

    body_a = _config_body()
    body_a["subdomain"] = "alpha"
    body_b = _config_body()
    body_b["subdomain"] = "beta"

    assert client.post("/api/deployments", json=body_a, headers=_auth(token_a)).status_code == 200
    assert client.post("/api/deployments", json=body_b, headers=_auth(token_b)).status_code == 200


def test_subdomain_exposed_in_list_and_detail(client):
    token = _register(client, "expose@acme.com")
    dep_id = client.post("/api/deployments", json=_config_body(), headers=_auth(token)).json()["id"]

    listing = client.get("/api/deployments", headers=_auth(token)).json()
    assert listing[0]["subdomain"] == "acme"
    detail = client.get(f"/api/deployments/{dep_id}", headers=_auth(token)).json()
    assert detail["subdomain"] == "acme"


def test_client_supplied_instance_type_ignored(client):
    """spec's #1 named risk: self-service spend on the platform's account.

    `ecs_instance_type` is not part of `DeploymentConfig`, so a client that sends
    it gets the platform's configured size regardless.
    """
    token = _register(client, "spend@acme.com")
    body = _config_body()
    body["ecs_instance_type"] = "ecs.gn7i-c8g1.2xlarge"
    r = client.post("/api/deployments", json=body, headers=_auth(token))
    assert r.status_code == 200

    db = _db(client)
    try:
        stored = db.query(Deployment).all()[0]
    finally:
        db.close()
    assert "ecs_instance_type" not in stored.config


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


def _set_run_status(client, dep_id, run_type, status):
    db = _db(client)
    try:
        db.query(Run).filter(Run.deployment_id == dep_id, Run.type == run_type).first().status = status
        db.commit()
    finally:
        db.close()


def _mark_deployed(client, dep_id):
    """把部署置为"create 已跑完且成功"：create run 终态 + status=succeeded。

    真实流程里只有 create run 结束后才是这个状态。这些用例必须先把在途 create
    run 收尾，否则会先被守卫 2（create 在途）挡下，守卫 1/3 就失去了覆盖。
    """
    _set_run_status(client, dep_id, "create", "succeeded")
    _set_status(client, dep_id, "succeeded")


def test_destroy_rejected_when_not_deployed(client):
    """draft 且无在途 run → 确定无物可销毁。"""
    token, dep_id = _create_dep(client, "d1@acme.com")
    _set_run_status(client, dep_id, "create", "succeeded")  # 隔离守卫 3

    r = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert r.status_code == 400
    assert "nothing to destroy" in r.json()["detail"]
    assert _destroy_runs(client, dep_id) == []


def test_destroy_rejected_when_create_in_flight(client):
    """create 还在跑时不能销毁 —— 不能一边建一边删。"""
    token, dep_id = _create_dep(client, "d5@acme.com")  # 刚创建 → create run 为 pending

    # 断言"拒绝的原因是在途 create"，而不是只断言 400：否则守卫 3 也能让这个用例变绿，
    # 用例就失去意义了。措辞不锁死（"create in progress" / "create already in progress" 都算）。
    r = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert r.status_code == 400
    assert "create" in r.json()["detail"] and "progress" in r.json()["detail"]

    _set_run_status(client, dep_id, "create", "running")
    r2 = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert r2.status_code == 400
    assert "create" in r2.json()["detail"] and "progress" in r2.json()["detail"]

    assert _destroy_runs(client, dep_id) == []


def test_destroy_rejected_when_already_destroyed(client):
    """已销毁的部署无物可销毁（否则会反复对空 state 跑 terraform destroy）。"""
    token, dep_id = _create_dep(client, "d6@acme.com")
    _mark_deployed(client, dep_id)
    _set_status(client, dep_id, "destroyed")

    r = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert r.status_code == 400
    assert "nothing to destroy" in r.json()["detail"]
    assert _destroy_runs(client, dep_id) == []


def test_destroy_rejected_when_destroy_already_pending(client):
    """重复 POST destroy 不能堆积 run —— 每个都会对已销毁的 state 再跑一次。"""
    token, dep_id = _create_dep(client, "d2@acme.com")
    _mark_deployed(client, dep_id)

    first = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert first.status_code == 200

    second = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert second.status_code == 400
    assert "destroy" in second.json()["detail"] and "progress" in second.json()["detail"]
    assert len(_destroy_runs(client, dep_id)) == 1


def test_destroy_rejected_when_destroy_running(client):
    """已在执行中的 destroy run 同样要挡住重复入队（status="running" 也要覆盖）。"""
    token, dep_id = _create_dep(client, "d3@acme.com")
    _mark_deployed(client, dep_id)

    assert client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token)).status_code == 200
    _set_run_status(client, dep_id, "destroy", "running")

    r = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert r.status_code == 400
    assert "destroy" in r.json()["detail"] and "progress" in r.json()["detail"]
    assert len(_destroy_runs(client, dep_id)) == 1


def test_destroy_allowed_when_deployed(client):
    """正向路径：已成功创建的部署可以销毁（守卫不能把正常用例也挡掉）。"""
    token, dep_id = _create_dep(client, "d4@acme.com")
    _mark_deployed(client, dep_id)

    r = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert r.status_code == 200
    assert r.json()["status"] == "pending"
    runs = _destroy_runs(client, dep_id)
    assert len(runs) == 1
    assert runs[0].status == "pending"


def test_destroy_allowed_when_deployment_failed(client):
    """create 失败（terraform apply 半途失败）会残留真实云资源，必须允许 destroy 清理。

    若守卫只放行 "succeeded"，失败部署就再无任何 API 路径清理资源
    （retry 只处理失败的 create run），孤儿资源会持续计费。
    """
    token, dep_id = _create_dep(client, "d7@acme.com")
    _set_run_status(client, dep_id, "create", "failed")
    _set_status(client, dep_id, "failed")

    r = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert r.status_code == 200
    assert r.json()["status"] == "pending"
    runs = _destroy_runs(client, dep_id)
    assert len(runs) == 1
    assert runs[0].status == "pending"


def test_destroy_allowed_after_failed_destroy(client):
    """destroy 自身失败后必须能再次 destroy —— 否则租户永久无法清理残留资源。

    create 成功 → destroy 允许 → destroy 跑一半失败（部署回到 "failed"）
    → 再次 POST destroy 必须 200，而不是被守卫永久 400 挡死。
    """
    token, dep_id = _create_dep(client, "d8@acme.com")
    _mark_deployed(client, dep_id)

    assert client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token)).status_code == 200
    _set_run_status(client, dep_id, "destroy", "failed")
    _set_status(client, dep_id, "failed")

    again = client.post(f"/api/deployments/{dep_id}/destroy", headers=_auth(token))
    assert again.status_code == 200
    assert again.json()["status"] == "pending"
    assert len(_destroy_runs(client, dep_id)) == 2
