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
