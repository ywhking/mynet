from datetime import datetime, timezone
from sqlalchemy import ForeignKey, String, Text, Integer, DateTime
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import JSON

from .db import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Tenant(Base):
    __tablename__ = "tenants"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(255))
    slug: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    status: Mapped[str] = mapped_column(String(16), default="active")
    quota: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    users: Mapped[list["User"]] = relationship(back_populates="tenant")
    deployments: Mapped[list["Deployment"]] = relationship(back_populates="tenant")


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    tenant_id: Mapped[int] = mapped_column(ForeignKey("tenants.id"))
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    role: Mapped[str] = mapped_column(String(16), default="admin")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    tenant: Mapped["Tenant"] = relationship(back_populates="users")


class Deployment(Base):
    __tablename__ = "deployments"
    id: Mapped[int] = mapped_column(primary_key=True)
    tenant_id: Mapped[int] = mapped_column(ForeignKey("tenants.id"), index=True)
    # Globally unique, not per tenant: `tfvars.py` turns it into
    # `<subdomain>.<platform_domain>` and `terraform/dns.tf` writes an A record
    # with that name into the single shared DNS zone, so two tenants using the
    # same prefix create competing records for one hostname. Registration is
    # fully self-service (spec §4), so nothing else gates it.
    subdomain: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    config: Mapped[dict] = mapped_column(JSON)
    secrets: Mapped[dict] = mapped_column(JSON, default=dict)
    status: Mapped[str] = mapped_column(String(16), default="draft")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    tenant: Mapped["Tenant"] = relationship(back_populates="deployments")
    runs: Mapped[list["Run"]] = relationship(back_populates="deployment")


class Run(Base):
    __tablename__ = "runs"
    id: Mapped[int] = mapped_column(primary_key=True)
    deployment_id: Mapped[int] = mapped_column(ForeignKey("deployments.id"), index=True)
    type: Mapped[str] = mapped_column(String(16))  # create | destroy
    status: Mapped[str] = mapped_column(String(16), default="pending")  # pending|running|succeeded|failed
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    log: Mapped[str] = mapped_column(Text, default="")
    started_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

    deployment: Mapped["Deployment"] = relationship(back_populates="runs")
