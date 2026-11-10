"""Application configuration, read exclusively from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass

_VALID_LOG_LEVELS = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    port: int
    log_level: str
    app_env: str
    app_version: str
    enable_error_endpoint: bool

    @classmethod
    def from_env(cls) -> Settings:
        log_level = os.getenv("LOG_LEVEL", "INFO").upper()
        if log_level not in _VALID_LOG_LEVELS:
            log_level = "INFO"
        return cls(
            port=int(os.getenv("PORT", "8080")),
            log_level=log_level,
            app_env=os.getenv("APP_ENV", "local"),
            app_version=os.getenv("APP_VERSION", "0.0.0-dev"),
            # Exposes GET /error (always 500) so dashboards/alerts can be demoed.
            # Off by default; never enable in production.
            enable_error_endpoint=_env_bool("ENABLE_ERROR_ENDPOINT", False),
        )
