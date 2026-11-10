from __future__ import annotations

import json
import logging
import sys
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


def make_settings(**overrides: object) -> Settings:
    base = {
        "port": 8080,
        "log_level": "INFO",
        "app_env": "test",
        "app_version": "1.2.3",
        "enable_error_endpoint": False,
    }
    base.update(overrides)
    return Settings(**base)  # type: ignore[arg-type]


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(create_app(make_settings())) as c:
        yield c


def test_root_returns_expected_payload(client: TestClient) -> None:
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json() == {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": "1.2.3",
    }


def test_health_ok(client: TestClient) -> None:
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_metrics_exposes_required_series(client: TestClient) -> None:
    client.get("/")
    client.get("/does-not-exist")
    body = client.get("/metrics").text
    assert "http_requests_total" in body
    assert "http_errors_total" in body
    assert "http_request_duration_seconds_bucket" in body
    assert 'path="/"' in body
    # Unknown URLs collapse to one label value to keep cardinality bounded.
    assert 'path="unmatched"' in body
    assert 'path="/does-not-exist"' not in body


def test_metrics_content_type(client: TestClient) -> None:
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/plain")


def test_error_endpoint_disabled_by_default(client: TestClient) -> None:
    assert client.get("/error").status_code == 404


def test_error_endpoint_counts_as_error() -> None:
    with TestClient(create_app(make_settings(enable_error_endpoint=True))) as c:
        assert c.get("/error").status_code == 500
        body = c.get("/metrics").text
    line = next(
        ln for ln in body.splitlines()
        if ln.startswith("http_errors_total{") and 'path="/error"' in ln
    )
    assert float(line.rsplit(" ", 1)[1]) >= 1


def test_logs_are_json(client: TestClient, capsys: pytest.CaptureFixture[str]) -> None:
    # configure_logging writes to the sys.stdout captured at handler creation;
    # rebind the handler to the pytest-captured stream.
    handler = logging.getLogger().handlers[0]
    assert isinstance(handler, logging.StreamHandler)
    handler.setStream(sys.stdout)
    client.get("/health")
    lines = [ln for ln in capsys.readouterr().out.splitlines() if ln.strip()]
    entry = json.loads(lines[-1])
    assert entry["level"] == "info"
    assert entry["path"] == "/health"
    assert entry["status"] == 200
    assert entry["env"] == "test"
    assert "duration_ms" in entry


def test_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PORT", "9000")
    monkeypatch.setenv("LOG_LEVEL", "debug")
    monkeypatch.setenv("APP_ENV", "staging")
    monkeypatch.setenv("APP_VERSION", "2.0.0")
    s = Settings.from_env()
    assert (s.port, s.log_level, s.app_env, s.app_version) == (9000, "DEBUG", "staging", "2.0.0")


def test_invalid_log_level_falls_back_to_info(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LOG_LEVEL", "chatty")
    assert Settings.from_env().log_level == "INFO"
