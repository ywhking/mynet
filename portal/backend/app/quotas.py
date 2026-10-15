import ipaddress
import re

from .schemas import DeploymentConfig

SUBDOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")


def _cidr(s: str) -> ipaddress.IPv4Network:
    try:
        return ipaddress.IPv4Network(s, strict=False)
    except ValueError:
        raise ValueError(f"invalid CIDR: {s}")


def validate_config(config: DeploymentConfig, quota: dict, running_count: int) -> list[str]:
    errors: list[str] = []

    if not SUBDOMAIN_RE.match(config.subdomain):
        errors.append(f"invalid subdomain: {config.subdomain}")

    try:
        vpc = _cidr(config.vpc_cidr)
        pub = _cidr(config.public_devices.cidr)
        internal = _cidr(config.internal_devices.cidr)
    except ValueError as e:
        return [str(e)]

    if not (vpc.network_address <= pub.network_address and pub.broadcast_address <= vpc.broadcast_address):
        errors.append("public_devices.cidr must be within vpc_cidr")
    if not (vpc.network_address <= internal.network_address and internal.broadcast_address <= vpc.broadcast_address):
        errors.append("internal_devices.cidr must be within vpc_cidr")
    if pub.overlaps(internal):
        errors.append("public and internal subnets overlap")

    pub_instances = config.public_devices.instances
    bastions = [k for k, v in pub_instances.items() if v.is_bastion]
    if len(bastions) != 1:
        errors.append("exactly one bastion (is_bastion=true) is required")
    for k, v in pub_instances.items():
        if v.is_bastion and not v.public_ip:
            errors.append(f"bastion {k} must have public_ip=true")
        if not v.public_ip:
            errors.append(f"public instance {k} must have public_ip=true")
        if not v.domain_name:
            errors.append(f"public instance {k} missing domain_name")

    total_vms = len(pub_instances) + len(config.internal_devices.instances)
    if total_vms > quota.get("max_vms", 10):
        errors.append(f"VM count {total_vms} exceeds quota max_vms={quota.get('max_vms', 10)}")

    max_running = quota.get("max_running", 1)
    if running_count >= max_running:
        errors.append(f"tenant already has {running_count} running deployment(s), max {max_running}")

    return errors
