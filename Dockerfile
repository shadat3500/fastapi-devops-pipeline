# syntax=docker/dockerfile:1.7

# Base image pinned to an exact Python patch + Alpine version. It is written literally in
# both FROM lines (not via ARG) so hadolint (DL3006) and Dependabot can both read the tag.
# To pin by digest as well:
#   docker buildx imagetools inspect python:3.13.9-alpine3.22 --format '{{json .Manifest.Digest}}'
# then use python:3.13.9-alpine3.22@sha256:<digest>

# ---------- Stage 1: build dependencies into an isolated virtualenv ----------
FROM python:3.13.9-alpine3.22 AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-compile -r requirements.txt \
 && /opt/venv/bin/pip uninstall -y pip

# ---------- Stage 2: minimal runtime ----------
FROM python:3.13.9-alpine3.22 AS runtime

ARG APP_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG SOURCE_URL=https://github.com/OWNER/REPO

LABEL org.opencontainers.image.title="devops-app" \
      org.opencontainers.image.description="DevOps assessment web service (FastAPI)" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.licenses="MIT"

# 1. Pull in Alpine security fixes released after the base image was built
#    (e.g. OpenSSL CVE-2026-31789, fixed in 3.5.6-r0). Only the named packages are
#    upgraded, so the rest of the base image stays as pinned.
# 2. Remove pip from the runtime image (not needed at runtime, smaller CVE surface).
# 3. Create an unprivileged user with a fixed UID (matches k8s runAsUser).
# hadolint ignore=DL3017,DL3018
RUN apk upgrade --no-cache libcrypto3 libssl3 \
 && python -m pip uninstall -y pip \
 && addgroup -S -g 10001 app \
 && adduser -S -D -H -u 10001 -G app -s /sbin/nologin app

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    LOG_LEVEL=INFO \
    APP_ENV=production \
    APP_VERSION=${APP_VERSION}

WORKDIR /srv
COPY --from=builder /opt/venv /opt/venv
COPY --chown=root:root app/ ./app/

USER 10001:10001
EXPOSE 8080

# No curl/wget needed: use the interpreter that's already in the image.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import os,sys,urllib.request; sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\",\"8080\")}/health', timeout=2).status == 200 else 1)"]

# Exec form: python is PID 1 and receives SIGTERM directly -> graceful shutdown.
ENTRYPOINT ["python", "-m", "app.main"]
