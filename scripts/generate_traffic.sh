#!/usr/bin/env bash
# Generate demo traffic against the app so the dashboards and alerts have data.
#
# Usage: generate_traffic.sh [-u BASE_URL] [-d SECONDS] [-r REQ_PER_SEC] [-e ERROR_PERCENT]
#   -u  base URL                       default: http://localhost:8080
#   -d  duration in seconds            default: 300
#   -r  requests per second (approx.)  default: 10
#   -e  % of requests sent to /error   default: 0   (needs ENABLE_ERROR_ENDPOINT=true;
#                                                    otherwise they become 404s)
#   -h  show this help
#
# Example error spike:  generate_traffic.sh -u http://localhost:8082 -d 420 -r 10 -e 20
set -euo pipefail

BASE_URL="http://localhost:8080"
DURATION=300
RPS=10
ERROR_PCT=0

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts ":u:d:r:e:h" opt; do
  case "$opt" in
    u) BASE_URL="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    r) RPS="$OPTARG" ;;
    e) ERROR_PCT="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) echo "option -$OPTARG needs a value" >&2; usage >&2; exit 64 ;;
    *) echo "unknown option -$OPTARG" >&2; usage >&2; exit 64 ;;
  esac
done

for v in DURATION RPS ERROR_PCT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "$v must be a non-negative integer" >&2; exit 64; }
done
(( RPS > 0 )) || { echo "RPS must be > 0" >&2; exit 64; }

paths=("/" "/" "/" "/health" "/does-not-exist")
end=$((SECONDS + DURATION))
sent=0
echo "Sending ~${RPS} req/s to ${BASE_URL} for ${DURATION}s (${ERROR_PCT}% to /error)"

while (( SECONDS < end )); do
  for ((i = 0; i < RPS; i++)); do
    if (( RANDOM % 100 < ERROR_PCT )); then
      path="/error"
    else
      path="${paths[RANDOM % ${#paths[@]}]}"
    fi
    curl -s -o /dev/null --max-time 2 "${BASE_URL}${path}" &
    sent=$((sent + 1))
  done
  wait
  sleep 1
done

echo "Done: ${sent} requests sent"
