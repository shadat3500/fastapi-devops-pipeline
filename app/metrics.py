"""Prometheus metric definitions."""

from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram

# `path` is always the *route template* (e.g. "/", "/health") or "unmatched",
# never the raw URL, so label cardinality stays bounded.
REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests processed.",
    ["method", "path", "status"],
)

ERRORS = Counter(
    "http_errors_total",
    "Total HTTP requests that resulted in a 5xx response or an unhandled exception.",
    ["method", "path"],
)

LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "HTTP requests currently being processed.",
)

APP_INFO = Gauge(
    "app_info",
    "Static application info; value is always 1.",
    ["version", "env"],
)
