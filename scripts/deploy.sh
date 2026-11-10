#!/usr/bin/env bash
# Deploy one image tag on this host, smoke-test it, and roll back automatically on failure.
#
# Usage: deploy.sh <image> <tag>
#   e.g. APP_ENV=production APP_HOST_PORT=8081 deploy.sh ghcr.io/owner/repo 1.0.12
#
# Environment:
#   APP_ENV          environment name (staging|production)       default: production
#   APP_HOST_PORT    host port mapped to container port 8080      default: 8080
#   DEPLOY_DIR       where state (current/previous tag) is kept   default: $HOME/devops-app
#   HEALTH_RETRIES   smoke-test attempts                          default: 10
#   HEALTH_INTERVAL  seconds between attempts                     default: 3
#
# Exit codes: 0 deployed; 1 new release failed and was rolled back (or nothing to roll back to);
#             2 rollback ALSO failed - service is down, page a human.
set -euo pipefail

readonly CONTAINER_PORT=8080
readonly NETWORK=devops-app-net

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

log() { printf '%s [deploy] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
if [[ $# -ne 2 ]]; then usage >&2; exit 64; fi

IMAGE="$1"
NEW_TAG="$2"
APP_ENV="${APP_ENV:-production}"
APP_HOST_PORT="${APP_HOST_PORT:-8080}"
DEPLOY_DIR="${DEPLOY_DIR:-$HOME/devops-app}"
HEALTH_RETRIES="${HEALTH_RETRIES:-10}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-3}"

CONTAINER="devops-app-${APP_ENV}"
STATE_DIR="${DEPLOY_DIR}/${APP_ENV}"
CURRENT_FILE="${STATE_DIR}/current_tag"
HISTORY_FILE="${STATE_DIR}/history.log"
ENV_FILE="${STATE_DIR}/app.env"   # optional extra env vars / secrets, never in git

mkdir -p "$STATE_DIR"

run_container() {
  local tag="$1"
  local -a args=(
    --detach
    --name "$CONTAINER"
    --restart unless-stopped
    --network "$NETWORK"
    --publish "${APP_HOST_PORT}:${CONTAINER_PORT}"
    --env "APP_ENV=${APP_ENV}"
    --env "LOG_LEVEL=INFO"
    --read-only --tmpfs /tmp
    --cap-drop ALL --security-opt no-new-privileges:true
    --memory 256m --cpus 0.5
    --label "logging.service=app"
    --label "app.environment=${APP_ENV}"
    --log-opt max-size=10m --log-opt max-file=3
  )
  if [[ -f "$ENV_FILE" ]]; then
    args+=(--env-file "$ENV_FILE")
  fi
  docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
  docker run "${args[@]}" "${IMAGE}:${tag}" >/dev/null
}

smoke_test() {
  local i
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if curl --fail --silent --show-error --max-time 3 \
         "http://127.0.0.1:${APP_HOST_PORT}/health" >/dev/null 2>&1; then
      log "smoke test passed (attempt ${i}/${HEALTH_RETRIES})"
      return 0
    fi
    log "smoke test attempt ${i}/${HEALTH_RETRIES} failed; retrying in ${HEALTH_INTERVAL}s"
    sleep "$HEALTH_INTERVAL"
  done
  return 1
}

main() {
  local previous=""
  if [[ -s "$CURRENT_FILE" ]]; then
    previous="$(<"$CURRENT_FILE")"
  fi
  log "env=${APP_ENV} container=${CONTAINER} port=${APP_HOST_PORT}"
  log "deploying ${IMAGE}:${NEW_TAG} (previous: ${previous:-none})"

  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null

  # Pull first: if the pull fails, the running release is untouched.
  docker pull --quiet "${IMAGE}:${NEW_TAG}" >/dev/null

  run_container "$NEW_TAG"
  if smoke_test; then
    printf '%s\n' "$NEW_TAG" >"$CURRENT_FILE"
    printf '%s deployed %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NEW_TAG" >>"$HISTORY_FILE"
    log "SUCCESS: ${IMAGE}:${NEW_TAG} is live"
    return 0
  fi

  log "FAILURE: ${NEW_TAG} did not become healthy. Last container logs:"
  docker logs --tail 30 "$CONTAINER" >&2 2>&1 || true
  printf '%s failed %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NEW_TAG" >>"$HISTORY_FILE"

  if [[ -z "$previous" || "$previous" == "$NEW_TAG" ]]; then
    log "no previous release to roll back to"
    docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
    return 1
  fi

  log "ROLLBACK: restoring ${IMAGE}:${previous}"
  run_container "$previous"
  if smoke_test; then
    printf '%s rolled-back-to %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$previous" >>"$HISTORY_FILE"
    log "rollback to ${previous} succeeded; failing the deploy so CI shows red"
    return 1
  fi

  log "CRITICAL: rollback to ${previous} also failed - manual intervention required"
  return 2
}

main
