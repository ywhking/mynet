import re
from functools import lru_cache

from pydantic_settings import BaseSettings

# The value that ships in this file. Anyone who can read the source can forge a
# token signed with it for *any* email, i.e. cross-tenant access to every
# deployment. It is therefore refused at startup unless explicitly allowed.
INSECURE_JWT_DEFAULT = "dev-secret-change-me"

# setup-netbird.yml asserts the Let's Encrypt address is not a placeholder.
# Keeping the same pattern here turns a guaranteed mid-run Ansible failure into
# a startup error.
UNUSABLE_EMAIL_RE = re.compile(r"@(example|test|invalid)\.(com|org|net|edu)$", re.IGNORECASE)


class Settings(BaseSettings):
    database_url: str = "sqlite:///./portal.db"
    jwt_secret_key: str = INSECURE_JWT_DEFAULT
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24
    # Escape hatch for local development only. Never set this in a real
    # deployment: it re-enables the forgeable default JWT secret.
    allow_insecure_dev_defaults: bool = False

    platform_domain: str = "yourplatform.example.com"
    alicloud_region: str = "cn-wulanchabu"
    vswitch_zone: str = "cn-wulanchabu-a"

    # ecs_instance_type is deliberately NOT client-supplied: it is billed to the
    # platform's Alibaba Cloud account, so letting tenants pick (e.g.) the
    # largest instance is unbounded self-service spend.
    ecs_instance_type: str = "ecs.t6-c1m2.large"

    # Relative to the documented launch cwd: `cd portal/backend && uvicorn app.main:app`
    # (see the Task 10 README), where the repo root sits two levels up.
    terraform_dir: str = "../../terraform"
    # Per-tenant terraform working directories. Each tenant gets
    # `<tenants_dir>/<slug>/` containing a copy of terraform_dir's *.tf and
    # scripts/, so `path.module/keys/` (the locally generated SSH key pairs) and
    # the state file are never shared between tenants.
    tenants_dir: str = "../../terraform/.tenants"
    ansible_dir: str = "../../terraform/ansible"
    # Relative to ansible_dir (the cwd the playbooks and inventory script run in).
    inventory_script: str = "inventory/generate_inventory.sh"

    # Built SPA bundle, served by the API so the app stays same-origin: the
    # frontend calls /api with relative paths and no CORS is configured.
    # Relative to the backend cwd, so the default resolves to
    # portal/frontend/dist both locally and inside the image
    # (/app/portal/frontend/dist).
    frontend_dist: str = "../frontend/dist"

    alicloud_access_key: str = ""
    alicloud_secret_key: str = ""

    worker_max_concurrency: int = 1
    quota_max_vms: int = 10
    quota_max_running_deployments: int = 1

    netbird_letsencrypt_email: str = ""

    # Optional Ansible playbook inputs. Empty means "do not forward", which
    # leaves the playbook's own default in force.
    netbird_package: str = ""
    netbird_binary: str = ""
    docker_repo_base: str = ""
    docker_mirrors: str = ""

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


def validate_runtime_settings(settings: Settings) -> None:
    """Refuse to start with values that guarantee a broken (or unsafe) run.

    Called by both the API app and the worker at startup: a misconfiguration
    that only surfaces mid-`terraform apply` costs the tenant a failed run and
    leaves cloud resources half-built.
    """
    errors: list[str] = []

    if settings.jwt_secret_key == INSECURE_JWT_DEFAULT and not settings.allow_insecure_dev_defaults:
        errors.append(
            "JWT_SECRET_KEY is still the built-in development default "
            f"({INSECURE_JWT_DEFAULT!r}); anyone can forge a token for any email. "
            "Set JWT_SECRET_KEY in portal/backend/.env (or set "
            "ALLOW_INSECURE_DEV_DEFAULTS=true for local development only)."
        )

    email = settings.netbird_letsencrypt_email.strip()
    if not email:
        errors.append(
            "NETBIRD_LETSENCRYPT_EMAIL is empty; the netbird playbook requires a real "
            "Let's Encrypt notification address. Set it in portal/backend/.env."
        )
    elif UNUSABLE_EMAIL_RE.search(email):
        errors.append(
            f"NETBIRD_LETSENCRYPT_EMAIL={email!r} is a placeholder address; the netbird "
            "playbook rejects @example/@test/@invalid domains. Set a real mailbox."
        )

    if errors:
        raise RuntimeError("invalid portal configuration:\n  - " + "\n  - ".join(errors))


@lru_cache
def get_settings() -> Settings:
    return Settings()
