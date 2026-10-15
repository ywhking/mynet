from .config import Settings
from .schemas import DeploymentConfig


def _quote(s: str) -> str:
    return f'"{s}"'


def generate_tfvars(config: DeploymentConfig, tenant_slug: str, settings: Settings) -> str:
    lines: list[str] = []
    lines.append(f"alicloud_region = {_quote(settings.alicloud_region)}")
    lines.append(f"vswitch_zone = {_quote(settings.vswitch_zone)}")
    lines.append(f"vpc_cidr = {_quote(config.vpc_cidr)}")
    lines.append(f"resource_group_name = {_quote(f'mynet-{tenant_slug}')}")
    lines.append(f"ecs_instance_type = {_quote(config.ecs_instance_type)}")
    lines.append(f"domain_name = {_quote(f'{config.subdomain}.{settings.platform_domain}')}")
    lines.append("")

    lines.append("public_devices = {")
    lines.append(f"  cidr = {_quote(config.public_devices.cidr)}")
    lines.append("  instances = {")
    for name, inst in config.public_devices.instances.items():
        lines.append(f"    {_quote(name)} = {{")
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
        lines.append(f"    {_quote(name)} = {{")
        lines.append(f"      host_name = {_quote(inst.host_name)}")
        lines.append("    }")
    lines.append("  }")
    lines.append("}")

    return "\n".join(lines) + "\n"
