from functools import lru_cache
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "sqlite:///./portal.db"
    jwt_secret_key: str = "dev-secret-change-me"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24

    platform_domain: str = "yourplatform.example.com"
    alicloud_region: str = "cn-wulanchabu"
    vswitch_zone: str = "cn-wulanchabu-a"

    # Relative to the documented launch cwd: `cd portal/backend && uvicorn app.main:app`
    # (see the Task 10 README), where the repo root sits two levels up.
    terraform_dir: str = "../../terraform"
    ansible_dir: str = "../../terraform/ansible"
    # Relative to ansible_dir (the cwd the playbooks and inventory script run in).
    inventory_script: str = "inventory/generate_inventory.sh"

    alicloud_access_key: str = ""
    alicloud_secret_key: str = ""

    worker_max_concurrency: int = 1
    quota_max_vms: int = 10
    quota_max_running_deployments: int = 1

    netbird_letsencrypt_email: str = "admin@yourplatform.example.com"

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


@lru_cache
def get_settings() -> Settings:
    return Settings()
