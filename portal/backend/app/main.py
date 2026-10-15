from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse

from .config import get_settings, validate_runtime_settings
from .db import Base, engine
from .routers import auth, deployments

INDEX_FILE = "index.html"


def _spa_root() -> Path:
    """Directory holding the built SPA bundle. Patched in tests."""
    return Path(get_settings().frontend_dist)


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

    # Registered last, so the API routes above win. This is what keeps the SPA
    # and the API on ONE origin — `src/api.ts` calls relative `/api/...` paths
    # and no CORS is configured, so a separate static host would break every
    # request (and `window.location.assign("/login")` with it).
    @app.get("/{full_path:path}", include_in_schema=False)
    def spa(full_path: str) -> FileResponse:
        # An unknown /api path is a genuine 404. Returning index.html with a 200
        # would hand `fetch()` HTML to JSON.parse().
        if full_path == "api" or full_path.startswith("api/"):
            raise HTTPException(status_code=404, detail="Not Found")

        root = _spa_root().resolve()
        index = root / INDEX_FILE
        if not index.is_file():
            raise HTTPException(
                status_code=404, detail="SPA bundle not built (run `npm run build`)"
            )

        if full_path:
            candidate = (root / full_path).resolve()
            # `.resolve()` + containment: a symlink or `..` inside the bundle
            # must not be able to reach outside it.
            if candidate.is_file() and candidate.is_relative_to(root):
                return FileResponse(candidate)

        # Everything else is a client-side route (`/login`, `/deployments/1`),
        # which only reaches the server on a hard refresh or a direct link.
        return FileResponse(index)

    return app


app = create_app()
