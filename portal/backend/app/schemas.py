from pydantic import BaseModel, EmailStr, Field


class RegisterRequest(BaseModel):
    tenant_name: str = Field(min_length=1, max_length=255)
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class PublicInstance(BaseModel):
    host_name: str
    domain_name: str
    public_ip: bool = True
    is_bastion: bool = False


class InternalInstance(BaseModel):
    host_name: str


class PublicDevices(BaseModel):
    cidr: str
    instances: dict[str, PublicInstance]


class InternalDevices(BaseModel):
    cidr: str
    instances: dict[str, InternalInstance]


class DeploymentConfig(BaseModel):
    subdomain: str
    public_devices: PublicDevices
    internal_devices: InternalDevices
    vpc_cidr: str = "172.16.0.0/16"
    # No `ecs_instance_type`: the instance size is billed to the platform's
    # Alibaba Cloud account, so it comes from Settings, never from the request.
    # (Extra keys in the body are ignored by pydantic, so a client trying to set
    # it anyway has no effect.)
