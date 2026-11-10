"""DevOps assessment web service."""

from __future__ import annotations

import logging
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from starlette.routing import Match

from app.config import Settings
from app.logging_setup import configure_logging
from app.metrics import APP_INFO, ERRORS, IN_PROGRESS, LATENCY, REQUESTS

logger = logging.getLogger("app")


def _route_template(request: Request) -> str:
    """Return the matched route path (bounded cardinality) or 'unmatched'."""
    for route in request.app.router.routes:
        match, _ = route.matches(request.scope)
        if match == Match.FULL:
            return getattr(route, "path", "unmatched")
    return "unmatched"


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    configure_logging(settings.log_level, settings.app_env, settings.app_version)

    state = {"shutting_down": False}

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        APP_INFO.labels(version=settings.app_version, env=settings.app_env).set(1)
        logger.info("startup complete", extra={"port": settings.port})
        yield
        # Uvicorn calls this after receiving SIGTERM/SIGINT, once it has stopped
        # accepting new connections and in-flight requests have finished.
        state["shutting_down"] = True
        logger.info("shutdown complete, exiting")

    app = FastAPI(title="devops-app", version=settings.app_version, lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware("http")
    async def observe(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        path = _route_template(request)
        method = request.method
        start = time.perf_counter()
        IN_PROGRESS.inc()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        except Exception:
            logger.exception("unhandled exception", extra={"path": path, "method": method})
            return JSONResponse({"detail": "internal server error"}, status_code=500)
        finally:
            duration = time.perf_counter() - start
            IN_PROGRESS.dec()
            REQUESTS.labels(method=method, path=path, status=str(status)).inc()
            LATENCY.labels(method=method, path=path).observe(duration)
            if status >= 500:
                ERRORS.labels(method=method, path=path).inc()
            if path != "/metrics":  # don't spam logs with every scrape
                level = logging.ERROR if status >= 500 else logging.WARNING if status >= 400 else logging.INFO
                logger.log(level, "request", extra={
                    "method": method,
                    "path": path,
                    "status": status,
                    "duration_ms": round(duration * 1000, 2),
                    "client": request.client.host if request.client else None,
                })

    @app.get("/")
    async def root() -> dict[str, str]:
        return {"message": "Hello from DevOps Task!", "status": "running", "version": settings.app_version}

    @app.get("/health")
    async def health() -> JSONResponse:
        if state["shutting_down"]:
            return JSONResponse({"status": "shutting_down"}, status_code=503)
        # DEMO ONLY: deliberately broken release to prove CD auto-rollback.
        # Passes unit tests and CI smoke test, fails the staging smoke test. Reverted after the demo.
        if settings.app_env == "staging":
            return JSONResponse({"status": "broken", "reason": "rollback demo"}, status_code=500)
        return JSONResponse({"status": "ok"})

    @app.get("/metrics")
    async def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    if settings.enable_error_endpoint:
        @app.get("/error")
        async def error() -> JSONResponse:
            logger.error("simulated failure requested")
            return JSONResponse({"detail": "simulated error"}, status_code=500)

    return app


def run() -> None:
    settings = Settings.from_env()
    uvicorn.run(
        create_app(settings),
        host="0.0.0.0",  # noqa: S104 - container must listen on all interfaces
        port=settings.port,
        log_config=None,          # keep our JSON logging config
        timeout_graceful_shutdown=20,  # drain in-flight requests on SIGTERM
        proxy_headers=True,
    )


if __name__ == "__main__":
    run()
