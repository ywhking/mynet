from sqlalchemy import select

from app.models import Tenant, User, Deployment, Run


def test_tenant_user_deployment_run_roundtrip(db_factory):
    db = db_factory()
    t = Tenant(name="Acme", slug="acme")
    db.add(t)
    db.commit()
    u = User(tenant_id=t.id, email="a@acme.com", password_hash="x")
    db.add(u)
    db.commit()
    d = Deployment(tenant_id=t.id, config={"subdomain": "acme"})
    db.add(d)
    db.commit()
    r = Run(deployment_id=d.id, type="create", status="pending")
    db.add(r)
    db.commit()

    got = db.scalar(select(Run).where(Run.id == r.id))
    assert got.deployment.tenant_id == t.id
    assert got.deployment.tenant.slug == "acme"
    db.close()
