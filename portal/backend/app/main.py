from fastapi import FastAPI

from .db import Base, engine
from .routers import auth, deployments


def create_app() -> FastAPI:
    app = FastAPI(title="Infra Provisioning Portal")
    app.include_router(auth.router, prefix="/api/auth", tags=["auth"])
    app.include_router(deployments.router, prefix="/api/deployments", tags=["deployments"])

    @app.on_event("startup")
    def _startup() -> None:
        Base.metadata.create_all(bind=engine)

    @app.get("/api/health")
    def health() -> dict:
        return {"status": "ok"}

    return app


app = create_app()
