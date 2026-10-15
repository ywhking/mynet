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
  // No ecs_instance_type: the ECS size is billed to the platform's Alibaba Cloud
  // account, so the server reads it from its own settings and ignores any value
  // sent here.
}
export interface RunInfo {
  id: number;
  type: string;
  status: string;
  error?: string | null;
  log?: string;
}
