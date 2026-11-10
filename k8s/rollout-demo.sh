#!/usr/bin/env bash
# Demonstrate a zero-downtime rolling update and a rollback (kubectl rollout undo).
#
# While the Deployment is updated and then rolled back, a background probe sends a
# request every 0.2s through the Ingress and records the HTTP status and app version.
# Zero non-200 responses = zero downtime.
#
# Usage: k8s/rollout-demo.sh <new-tag> [namespace] [host]
#   new-tag    image tag to roll out, e.g. 1.0.2
#   namespace  default: devops-staging
#   host       default: staging.devops-app.localhost (ingress on 127.0.0.1:18080)
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 64; }

NEW_TAG="$1"
NS="${2:-devops-staging}"
HOST="${3:-staging.devops-app.localhost}"
PORT=18080
DEPLOY=deployment/devops-app
IMAGE_REPO="ghcr.io/shadat3500/fastapi-devops-pipeline"
PROBE_LOG="$(mktemp)"
trap 'rm -f "$PROBE_LOG"' EXIT

for bin in kubectl curl; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

step() { printf '\n\033[1m$ %s\033[0m\n' "$*"; "$@"; }

probe() {
  while :; do
    body="$(curl -s --max-time 1 --resolve "${HOST}:${PORT}:127.0.0.1" \
             -w ' %{http_code}' "http://${HOST}:${PORT}/" || echo ' 000')"
    code="${body##* }"
    version="$(grep -o '"version":"[^"]*"' <<<"$body" | cut -d'"' -f4 || true)"
    printf '%s %s %s\n' "$(date +%T.%N | cut -c1-12)" "$code" "${version:--}" >>"$PROBE_LOG"
    sleep 0.2
  done
}

summary() {
  local total fails
  total=$(wc -l <"$PROBE_LOG")
  fails=$(awk '$2 != 200' "$PROBE_LOG" | wc -l)
  echo
  echo "=== probe summary: ${total} requests, ${fails} non-200 ==="
  echo "responses per (status, version):"
  awk '{print "  " $2 "  version=" $3}' "$PROBE_LOG" | sort | uniq -c
  if (( fails > 0 )); then
    echo "non-200 responses:"; awk '$2 != 200' "$PROBE_LOG" | head -20
  fi
}

old_image="$(kubectl -n "$NS" get "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "namespace=${NS} current image=${old_image} -> new tag=${NEW_TAG}"

probe & PROBE_PID=$!
trap 'kill "$PROBE_PID" 2>/dev/null || true; rm -f "$PROBE_LOG"' EXIT
sleep 2

echo; echo "##### 1. Rolling update to ${NEW_TAG} #####"
step kubectl -n "$NS" set image "$DEPLOY" "app=${IMAGE_REPO}:${NEW_TAG}"
step kubectl -n "$NS" annotate "$DEPLOY" kubernetes.io/change-cause="rollout demo: update to ${NEW_TAG}" --overwrite
step kubectl -n "$NS" rollout status "$DEPLOY" --timeout=180s
step kubectl -n "$NS" get pods -l app.kubernetes.io/component=web -o wide
step kubectl -n "$NS" rollout history "$DEPLOY"
sleep 3

echo; echo "##### 2. Rollback with kubectl rollout undo #####"
step kubectl -n "$NS" rollout undo "$DEPLOY"
step kubectl -n "$NS" rollout status "$DEPLOY" --timeout=180s
step kubectl -n "$NS" get "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
step kubectl -n "$NS" rollout history "$DEPLOY"
sleep 3

kill "$PROBE_PID" 2>/dev/null || true
wait "$PROBE_PID" 2>/dev/null || true
summary
