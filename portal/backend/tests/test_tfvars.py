from app.schemas import DeploymentConfig
from app.tfvars import generate_tfvars
from app.config import get_settings


def _config() -> DeploymentConfig:
    return DeploymentConfig(
        subdomain="acme",
        public_devices={
            "cidr": "172.16.0.0/24",
            "instances": {
                "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"},
            },
        },
        internal_devices={"cidr": "172.16.1.0/24", "instances": {"db": {"host_name": "db"}}},
    )


def test_generate_tfvars_contains_expected_values():
    s = get_settings()
    out = generate_tfvars(_config(), "acme", s)
    assert 'resource_group_name = "mynet-acme"' in out
    assert f'domain_name = "acme.{s.platform_domain}"' in out
    assert 'alicloud_region = "cn-wulanchabu"' in out
    assert 'vswitch_zone = "cn-wulanchabu-a"' in out
    assert 'is_bastion = true' in out
    # Map keys are slug-prefixed (spec §9) — they become `KEY-<key>` and the ECS
    # instance name, both of which are account-unique in Alibaba Cloud.
    assert '"mynet-acme-bastion"' in out
    assert '"mynet-acme-db"' in out
    # The tenant-supplied values themselves are passed through untouched.
    assert 'host_name = "bastion"' in out
    assert 'domain_name = "bastion"' in out


def test_instance_keys_are_unique_across_tenants():
    """Two tenants picking the same instance names must not collide.

    Regression guard for the `KeyPair.AlreadyExist` failure: the SPA defaults the
    public list to `bastion,web`, so this is the common path, not an edge case.
    """
    out_a = generate_tfvars(_config(), "tenant-a", get_settings())
    out_b = generate_tfvars(_config(), "tenant-b", get_settings())
    assert '"mynet-tenant-a-bastion"' in out_a
    assert '"mynet-tenant-b-bastion"' in out_b
    assert '"mynet-tenant-b-bastion"' not in out_a


def test_instance_type_comes_from_settings_not_the_config():
    """The ECS size is billed to the platform account, so it is not client input."""
    s = get_settings()
    out = generate_tfvars(_config(), "acme", s)
    assert f'ecs_instance_type = "{s.ecs_instance_type}"' in out
    # DeploymentConfig no longer has the field at all.
    assert "ecs_instance_type" not in DeploymentConfig.model_fields


def test_generate_tfvars_quotes_values():
    out = generate_tfvars(_config(), "acme", get_settings())
    assert '"172.16.0.0/24"' in out


def test_generate_tfvars_escapes_quotes_in_instance_values():
    config = DeploymentConfig(
        subdomain="acme",
        public_devices={
            "cidr": "172.16.0.0/24",
            "instances": {
                "bastion": {
                    "host_name": 'evil"name',
                    "public_ip": True,
                    "is_bastion": True,
                    "domain_name": 'evil"domain',
                },
            },
        },
        internal_devices={"cidr": "172.16.1.0/24", "instances": {"db": {"host_name": "db"}}},
    )
    out = generate_tfvars(config, "acme", get_settings())
    # Quotes must be escaped inside the HCL string literal, not emitted raw.
    assert 'evil\\"name' in out
    assert 'evil\\"domain' in out
    assert 'evil"name' not in out
    assert 'evil"domain' not in out


def test_generate_tfvars_escapes_backslash_and_newline():
    config = DeploymentConfig(
        subdomain="acme",
        public_devices={
            "cidr": "172.16.0.0/24",
            "instances": {
                "bastion": {
                    "host_name": "back\\slash",
                    "public_ip": True,
                    "is_bastion": True,
                    "domain_name": "line\nbreak",
                },
            },
        },
        internal_devices={"cidr": "172.16.1.0/24", "instances": {"db": {"host_name": "db"}}},
    )
    out = generate_tfvars(config, "acme", get_settings())
    assert "back\\\\slash" in out
    assert "line\\nbreak" in out
