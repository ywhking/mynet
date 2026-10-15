import json

from .config import Settings
from .schemas import DeploymentConfig


def _quote(s: str) -> str:
    # json.dumps produces a double-quoted string with `"`, `\`, control chars
    # and non-ASCII escaped using only sequences HCL also understands, so the
    # result is a valid HCL string literal and cannot break out of the quotes.
    return json.dumps(s)


def _instance_key(tenant_slug: str, name: str) -> str:
    """The terraform map key for one instance.

    The key is the raw tenant-supplied name in `terraform/ecs.tf`, where it
    becomes both `alicloud_key_pair.key_pair_name = "KEY-${each.key}"` and
    `alicloud_instance.instance_name`. Both are account/region-unique in
    Alibaba Cloud, so two tenants taking the SPA's default (`bastion,web`)
    collide: the second apply fails with `KeyPair.AlreadyExist`, and — worse —
    because `data.external.ssh_key` reuses `keys/KEY-<name>` if the file already
    exists, the second tenant's instances would be authorised with the *first*
    tenant's public key. Prefixing with `mynet-<slug>-` (spec §9: 所有阿里云资源名
    带 `mynet-<slug>` 前缀) makes the key globally unique per tenant.
    """
    return f"mynet-{tenant_slug}-{name}"


def generate_tfvars(config: DeploymentConfig, tenant_slug: str, settings: Settings) -> str:
    lines: list[str] = []
    lines.append(f"alicloud_region = {_quote(settings.alicloud_region)}")
    lines.append(f"vswitch_zone = {_quote(settings.vswitch_zone)}")
    lines.append(f"vpc_cidr = {_quote(config.vpc_cidr)}")
    lines.append(f"resource_group_name = {_quote(f'mynet-{tenant_slug}')}")
    # From settings, never from the request: the instance size is billed to the
    # platform account (spec's #1 named risk).
    lines.append(f"ecs_instance_type = {_quote(settings.ecs_instance_type)}")
    lines.append(f"domain_name = {_quote(f'{config.subdomain}.{settings.platform_domain}')}")
    lines.append("")

    lines.append("public_devices = {")
    lines.append(f"  cidr = {_quote(config.public_devices.cidr)}")
    lines.append("  instances = {")
    for name, inst in config.public_devices.instances.items():
        lines.append(f"    {_quote(_instance_key(tenant_slug, name))} = {{")
        lines.append(f"      host_name = {_quote(inst.host_name)}")
        lines.append(f"      public_ip = {str(inst.public_ip).lower()}")
        lines.append(f"      is_bastion = {str(inst.is_bastion).lower()}")
        lines.append(f"      domain_name = {_quote(inst.domain_name)}")
        lines.append("    }")
    lines.append("  }")
    lines.append("}")

    lines.append("")
    lines.append("internal_devices = {")
    lines.append(f"  cidr = {_quote(config.internal_devices.cidr)}")
    lines.append("  instances = {")
    for name, inst in config.internal_devices.instances.items():
        lines.append(f"    {_quote(_instance_key(tenant_slug, name))} = {{")
        lines.append(f"      host_name = {_quote(inst.host_name)}")
        lines.append("    }")
    lines.append("  }")
    lines.append("}")

    return "\n".join(lines) + "\n"
