import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.models import Tenant, User, Deployment, Run


def test_tenant_user_deployment_run_roundtrip(db_factory):
    db = db_factory()
    t = Tenant(name="Acme", slug="acme")
    db.add(t)
    db.commit()
    u = User(tenant_id=t.id, email="a@acme.com", password_hash="x")
    db.add(u)
    db.commit()
    d = Deployment(tenant_id=t.id, subdomain="acme", config={"subdomain": "acme"})
    db.add(d)
    db.commit()
    r = Run(deployment_id=d.id, type="create", status="pending")
    db.add(r)
    db.commit()

    got = db.scalar(select(Run).where(Run.id == r.id))
    assert got.deployment.tenant_id == t.id
    assert got.deployment.tenant.slug == "acme"
    assert got.deployment.subdomain == "acme"
    db.close()


def test_subdomain_is_globally_unique(db_factory):
    """The DB-level backstop behind the API's 400 (see create_deployment)."""
    db = db_factory()
    t1 = Tenant(name="One", slug="one")
    t2 = Tenant(name="Two", slug="two")
    db.add_all([t1, t2])
    db.commit()

    db.add(Deployment(tenant_id=t1.id, subdomain="acme", config={}))
    db.commit()

    db.add(Deployment(tenant_id=t2.id, subdomain="acme", config={}))
    with pytest.raises(IntegrityError):
        db.commit()
    db.rollback()
    db.close()
