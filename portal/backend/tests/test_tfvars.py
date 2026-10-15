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
    assert '"bastion"' in out and '"db"' in out


def test_generate_tfvars_quotes_values():
    out = generate_tfvars(_config(), "acme", get_settings())
    assert '"172.16.0.0/24"' in out
