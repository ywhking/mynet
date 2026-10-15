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

    # terraform/vpc.tf validates `tonumber(split("/", var.vpc_cidr)[1]) <= 16`
    # Because a /16 is the smallest block that provably holds two /24s, a larger
    # prefix (e.g. /17) passes the containment checks below only if the tenant
    # picked non-/24 subnets — and then fails inside `terraform apply`. Reject it
    # here so the tenant gets a clean 400 instead of a failed run.
    if vpc.prefixlen > 16:
        errors.append(
            f"vpc_cidr prefix /{vpc.prefixlen} is too long; must be /16 or shorter "
            "(prefix ≤ 16) to hold the two device subnets"
        )

    if not (vpc.network_address <= pub.network_address and pub.broadcast_address <= vpc.broadcast_address):
        errors.append("public_devices.cidr must be within vpc_cidr")
    if not (vpc.network_address <= internal.network_address and internal.broadcast_address <= vpc.broadcast_address):
        errors.append("internal_devices.cidr must be within vpc_cidr")
    if pub.overlaps(internal):
        errors.append("public and internal subnets overlap")

    pub_instances = config.public_devices.instances
    int_instances = config.internal_devices.instances

    # terraform/ecs.tf builds `local.all_instances = merge(public, internal)`, and
    # `merge` silently keeps one value on a key collision. A name used in both
    # maps therefore provisions ONE ECS, and the DNS/ansible stages then either
    # fail or act on the wrong group.
    duplicates = sorted(set(pub_instances) & set(int_instances))
    if duplicates:
        errors.append(
            "instance name(s) used in both public_devices and internal_devices: "
            + ", ".join(duplicates)
            + " (terraform merges the two maps, so only one instance would be created)"
        )

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

    total_vms = len(pub_instances) + len(int_instances)
    if total_vms > quota.get("max_vms", 10):
        errors.append(f"VM count {total_vms} exceeds quota max_vms={quota.get('max_vms', 10)}")

    max_running = quota.get("max_running", 1)
    if running_count >= max_running:
        errors.append(f"tenant already has {running_count} running deployment(s), max {max_running}")

    return errors
