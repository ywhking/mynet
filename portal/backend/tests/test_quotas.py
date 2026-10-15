from app.schemas import DeploymentConfig, InternalDevices, PublicDevices, PublicInstance, InternalInstance
from app.quotas import validate_config


def valid_config(**overrides):
    cfg = {
        "subdomain": "acme",
        "public_devices": {
            "cidr": "172.16.0.0/24",
            "instances": {
                "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"},
                "web": {"host_name": "web", "public_ip": True, "is_bastion": False, "domain_name": "web"},
            },
        },
        "internal_devices": {
            "cidr": "172.16.1.0/24",
            "instances": {"db": {"host_name": "db"}},
        },
    }
    cfg.update(overrides)
    return DeploymentConfig(**cfg)


def test_valid_config_passes():
    assert validate_config(valid_config(), {"max_vms": 10}, 0) == []


def test_no_bastion_rejected():
    cfg = valid_config()
    cfg.public_devices.instances["bastion"].is_bastion = False
    errs = validate_config(cfg, {"max_vms": 10}, 0)
    assert any("bastion" in e for e in errs)


def test_overlapping_subnets_rejected():
    cfg = valid_config(internal_devices={"cidr": "172.16.0.0/24", "instances": {"db": {"host_name": "db"}}})
    assert any("overlap" in e.lower() for e in validate_config(cfg, {"max_vms": 10}, 0))


def test_invalid_subdomain_rejected():
    cfg = valid_config(subdomain="bad sub!")
    assert any("subdomain" in e for e in validate_config(cfg, {"max_vms": 10}, 0))


def test_over_quota_vm_count_rejected():
    errs = validate_config(valid_config(), {"max_vms": 2}, 0)
    assert any("max_vms" in e or "quota" in e.lower() for e in errs)


def test_running_deployment_blocks_new_one():
    errs = validate_config(valid_config(), {"max_vms": 10, "max_running": 1}, 1)
    assert any("running" in e for e in errs)


def test_ipv6_cidr_rejected():
    cfg = valid_config(
        public_devices={
            "cidr": "fd00::/64",
            "instances": {
                "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"}
            },
        }
    )
    errs = validate_config(cfg, {"max_vms": 10}, 0)
    assert errs


def test_duplicate_instance_name_across_groups_rejected():
    """`terraform/ecs.tf` does `merge(public, internal)`, which silently drops one.

    A name in both maps provisions a single ECS instead of two.
    """
    cfg = valid_config(
        internal_devices={
            "cidr": "172.16.1.0/24",
            "instances": {"db": {"host_name": "db"}, "web": {"host_name": "web"}},
        }
    )
    errs = validate_config(cfg, {"max_vms": 10}, 0)
    assert any("web" in e and "both" in e for e in errs), errs


def test_distinct_names_across_groups_accepted():
    """The duplicate check must not fire on the normal case."""
    assert validate_config(valid_config(), {"max_vms": 10}, 0) == []


def test_vpc_cidr_prefix_longer_than_16_rejected():
    """terraform/vpc.tf validates prefix ≤ 16; catch it here as a clean 400.

    /17 with /24s does not even fit, but /17 with two /25s would pass the
    containment checks and then fail inside `terraform apply`.
    """
    cfg = valid_config(
        vpc_cidr="172.16.0.0/17",
        public_devices={
            "cidr": "172.16.0.0/25",
            "instances": {
                "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"}
            },
        },
        internal_devices={"cidr": "172.16.0.128/25", "instances": {"db": {"host_name": "db"}}},
    )
    errs = validate_config(cfg, {"max_vms": 10}, 0)
    assert any("vpc_cidr" in e for e in errs), errs


def test_vpc_cidr_16_accepted():
    assert validate_config(valid_config(vpc_cidr="172.16.0.0/16"), {"max_vms": 10}, 0) == []


def test_vpc_cidr_8_accepted():
    """Shorter prefixes (larger blocks) are fine — terraform allows ≤ 16."""
    cfg = valid_config(
        vpc_cidr="10.0.0.0/8",
        public_devices={
            "cidr": "10.0.0.0/24",
            "instances": {
                "bastion": {"host_name": "bastion", "public_ip": True, "is_bastion": True, "domain_name": "bastion"}
            },
        },
        internal_devices={"cidr": "10.0.1.0/24", "instances": {"db": {"host_name": "db"}}},
    )
    assert validate_config(cfg, {"max_vms": 10}, 0) == []
