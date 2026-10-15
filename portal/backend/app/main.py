from fastapi import FastAPI

from .config import get_settings, validate_runtime_settings
from .db import Base, engine
from .routers import auth, deployments


def create_app() -> FastAPI:
    app = FastAPI(title="Infra Provisioning Portal")
    app.include_router(auth.router, prefix="/api/auth", tags=["auth"])
    app.include_router(deployments.router, prefix="/api/deployments", tags=["deployments"])

    @app.on_event("startup")
    def _startup() -> None:
        # Fail fast rather than mint tokens with a publicly known secret or
        # accept deployments that will die at the netbird step.
        validate_runtime_settings(get_settings())
        Base.metadata.create_all(bind=engine)

    @app.get("/api/health")
    def health() -> dict:
        return {"status": "ok"}

    return app


app = create_app()
