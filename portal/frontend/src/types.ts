export interface PublicInstance {
  host_name: string;
  domain_name: string;
  public_ip: boolean;
  is_bastion: boolean;
}
export interface InternalInstance {
  host_name: string;
}
export interface DeploymentConfig {
  subdomain: string;
  public_devices: { cidr: string; instances: Record<string, PublicInstance> };
  internal_devices: { cidr: string; instances: Record<string, InternalInstance> };
  vpc_cidr?: string;
  ecs_instance_type?: string;
}
export interface RunInfo {
  id: number;
  type: string;
  status: string;
  error?: string | null;
  log?: string;
}
