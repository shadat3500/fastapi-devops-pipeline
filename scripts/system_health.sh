#!/usr/bin/env bash
#
# system_health.sh - host health check for production Linux servers.
#
# Collects CPU, memory, disk (all real mounted filesystems), load average and the
# top 5 processes by memory; prints a report, appends a timestamped entry to a log
# file (with size-based rotation) and exits with a monitoring-friendly status code.
#
# Usage: system_health.sh [options]
#
#   --cpu PCT          CPU usage warning threshold          (default: 90)
#   --mem PCT          memory usage warning threshold       (default: 85)
#   --disk PCT         disk usage warning threshold, any FS (default: 80)
#   --cpu-crit PCT     CPU critical threshold               (default: 95)
#   --mem-crit PCT     memory critical threshold            (default: 95)
#   --disk-crit PCT    disk critical threshold              (default: 90)
#   --json             print the report as JSON and log it as one JSON line
#   --log FILE         log file            (default: $HEALTH_LOG or ./health_log.txt)
#   --max-size KB      rotate log when larger than this     (default: 1024)
#   --keep N           rotated log files to keep            (default: 5)
#   --interval SEC     CPU sampling interval                (default: 1)
#   --no-log           don't write the log file
#   -q, --quiet        no report on stdout (warnings still go to stderr)
#   -h, --help         show this help
#
# Exit codes:  0 = healthy   1 = warning   2 = critical   3 = unknown (bad usage / error)
#
# Optional alerting: if HEALTH_WEBHOOK_URL is set (Slack or Discord incoming webhook),
# a message is POSTed whenever the status is warning or critical.
#
# Examples:
#   system_health.sh
#   system_health.sh --disk 70 --cpu 80 --json
#   HEALTH_WEBHOOK_URL=https://hooks.slack.com/services/... system_health.sh -q
#
set -euo pipefail

readonly EXIT_OK=0 EXIT_WARN=1 EXIT_CRIT=2 EXIT_UNKNOWN=3
readonly SCRIPT_NAME="${0##*/}"

# ----------------------------------------------------------------- defaults ---
cpu_warn=90  mem_warn=85  disk_warn=80
cpu_crit=95  mem_crit=95  disk_crit=90
output_json=false
log_enabled=true
quiet=false
log_file="${HEALTH_LOG:-./health_log.txt}"
max_size_kb=1024
keep=5
interval=1

# ------------------------------------------------------------------ helpers ---
usage() { sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'; }

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$EXIT_UNKNOWN"
}

# Any error not handled explicitly => UNKNOWN (3), never a misleading 1/2.
trap 'printf "%s: unexpected failure at line %s\n" "$SCRIPT_NAME" "$LINENO" >&2; exit $EXIT_UNKNOWN' ERR

is_pct() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v v="$1" 'BEGIN { exit !(v >= 0 && v <= 100) }'; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# float comparison: gt A B  -> true if A > B
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "option $1 requires a value"; }

# ------------------------------------------------------------ parse options ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)       need_value "$@"; cpu_warn="$2"; shift 2 ;;
    --mem)       need_value "$@"; mem_warn="$2"; shift 2 ;;
    --disk)      need_value "$@"; disk_warn="$2"; shift 2 ;;
    --cpu-crit)  need_value "$@"; cpu_crit="$2"; shift 2 ;;
    --mem-crit)  need_value "$@"; mem_crit="$2"; shift 2 ;;
    --disk-crit) need_value "$@"; disk_crit="$2"; shift 2 ;;
    --log)       need_value "$@"; log_file="$2"; shift 2 ;;
    --max-size)  need_value "$@"; max_size_kb="$2"; shift 2 ;;
    --keep)      need_value "$@"; keep="$2"; shift 2 ;;
    --interval)  need_value "$@"; interval="$2"; shift 2 ;;
    --json)      output_json=true; shift ;;
    --no-log)    log_enabled=false; shift ;;
    -q|--quiet)  quiet=true; shift ;;
    -h|--help)   usage; exit "$EXIT_OK" ;;
    *)           usage >&2; die "unknown option: $1" ;;
  esac
done

for pair in "cpu:$cpu_warn" "mem:$mem_warn" "disk:$disk_warn" \
            "cpu-crit:$cpu_crit" "mem-crit:$mem_crit" "disk-crit:$disk_crit"; do
  is_pct "${pair#*:}" || die "--${pair%%:*} must be a number between 0 and 100 (got '${pair#*:}')"
done
for pair in "cpu:$cpu_warn:$cpu_crit" "mem:$mem_warn:$mem_crit" "disk:$disk_warn:$disk_crit"; do
  IFS=: read -r name w c <<<"$pair"
  gt "$w" "$c" && die "--${name} (${w}) must not exceed --${name}-crit (${c})"
done
if ! is_uint "$max_size_kb" || (( max_size_kb < 1 )); then die "--max-size must be a positive integer (KB)"; fi
if ! is_uint "$keep" || (( keep < 1 )); then die "--keep must be an integer >= 1"; fi
if ! is_uint "$interval" || (( interval < 1 )); then die "--interval must be an integer >= 1"; fi

[[ -r /proc/stat && -r /proc/meminfo && -r /proc/loadavg ]] || die "this script needs Linux /proc"
for bin in awk df ps; do command -v "$bin" >/dev/null || die "missing dependency: $bin"; done

# --------------------------------------------------------------- collectors ---
# CPU: two samples of the aggregate "cpu" line in /proc/stat. Busy = total - idle - iowait.
read_cpu() { awk '/^cpu / { idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print total, idle; exit }' /proc/stat; }

read -r total1 idle1 < <(read_cpu)
sleep "$interval"
read -r total2 idle2 < <(read_cpu)
cpu_pct=$(awk -v t=$((total2 - total1)) -v i=$((idle2 - idle1)) 'BEGIN { printf "%.1f", (t > 0) ? 100 * (t - i) / t : 0 }')
cpu_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)

# Memory: MemAvailable is the kernel's estimate of memory usable without swapping.
read -r mem_total_kb mem_avail_kb swap_total_kb swap_free_kb < <(awk '
  /^MemTotal:/     { t = $2 }  /^MemAvailable:/ { a = $2 }
  /^SwapTotal:/    { st = $2 } /^SwapFree:/     { sf = $2 }
  END { print t, a, st, sf }' /proc/meminfo)
mem_used_kb=$((mem_total_kb - mem_avail_kb))
mem_pct=$(awk -v u="$mem_used_kb" -v t="$mem_total_kb" 'BEGIN { printf "%.1f", 100 * u / t }')
swap_pct=$(awk -v t="$swap_total_kb" -v f="$swap_free_kb" 'BEGIN { printf "%.1f", (t > 0) ? 100 * (t - f) / t : 0 }')

# Load average.
read -r load1 load5 load15 _ < /proc/loadavg

# Disks: every real filesystem (pseudo / in-memory / container overlay types excluded).
disk_lines=()
while IFS= read -r line; do
  disk_lines+=("$line")
done < <(df -P -k -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs -x ramfs 2>/dev/null \
           | awk 'NR > 1 && $2 > 0 { sub(/%$/, "", $5); print $6 "\t" $1 "\t" $2 "\t" $3 "\t" $5 }' \
           | sort -u)
(( ${#disk_lines[@]} > 0 )) || die "could not read any filesystem usage from df"

# Top 5 processes by memory.
top_procs=()
while IFS= read -r line; do
  top_procs+=("$line")
done < <(ps -eo pid=,user=,pmem=,rss=,comm= --sort=-pmem | head -n 5 \
           | awk '{ printf "%s\t%s\t%s\t%s\t", $1, $2, $3, $4; $1=$2=$3=$4=""; sub(/^ +/, ""); print }')

# ------------------------------------------------------------------ evaluate ---
status=$EXIT_OK
warnings=()

check() { # check <label> <value> <warn> <crit>
  local label="$1" value="$2" warn="$3" crit="$4"
  if gt "$value" "$crit"; then
    warnings+=("[CRITICAL] ${label} at ${value}% exceeds critical threshold ${crit}%")
    status=$EXIT_CRIT
  elif gt "$value" "$warn"; then
    warnings+=("[WARNING] ${label} at ${value}% exceeds threshold ${warn}%")
    (( status < EXIT_WARN )) && status=$EXIT_WARN
  fi
  return 0
}

check "CPU usage" "$cpu_pct" "$cpu_warn" "$cpu_crit"
check "Memory usage" "$mem_pct" "$mem_warn" "$mem_crit"
for line in "${disk_lines[@]}"; do
  IFS=$'\t' read -r mount _ _ _ pct <<<"$line"
  check "Disk usage on ${mount}" "$pct" "$disk_warn" "$disk_crit"
done
# Load is informational context, warned (never critical) when it exceeds the core count.
if gt "$load1" "$cpu_cores"; then
  warnings+=("[WARNING] 1-minute load ${load1} exceeds CPU core count ${cpu_cores}")
  (( status < EXIT_WARN )) && status=$EXIT_WARN
fi

case "$status" in
  "$EXIT_OK")   status_text="OK" ;;
  "$EXIT_WARN") status_text="WARNING" ;;
  *)            status_text="CRITICAL" ;;
esac

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
host="$(hostname)"

# ------------------------------------------------------------------ render ---
render_text() {
  local line mount fs size used pct pid user pmem rss cmd
  printf '=== System health: %s on %s - %s ===\n' "$timestamp" "$host" "$status_text"
  printf 'CPU:     %5s%%   (%s cores)\n' "$cpu_pct" "$cpu_cores"
  printf 'Memory:  %5s%%   (%s MiB used of %s MiB, swap %s%%)\n' \
    "$mem_pct" $((mem_used_kb / 1024)) $((mem_total_kb / 1024)) "$swap_pct"
  printf 'Load:    %s %s %s (1m 5m 15m)\n' "$load1" "$load5" "$load15"
  printf 'Disks:\n'
  for line in "${disk_lines[@]}"; do
    IFS=$'\t' read -r mount fs size used pct <<<"$line"
    printf '  %-24s %5s%%  %8s MiB of %8s MiB  (%s)\n' "$mount" "$pct" $((used / 1024)) $((size / 1024)) "$fs"
  done
  printf 'Top 5 processes by memory:\n'
  printf '  %-8s %-12s %6s %10s  %s\n' PID USER %MEM RSS_MiB COMMAND
  for line in "${top_procs[@]}"; do
    IFS=$'\t' read -r pid user pmem rss cmd <<<"$line"
    printf '  %-8s %-12s %6s %10s  %s\n' "$pid" "$user" "$pmem" $((rss / 1024)) "$cmd"
  done
  if (( ${#warnings[@]} > 0 )); then
    printf '%s\n' "${warnings[@]}"
  fi
}

render_json() {
  local line mount fs size used pct pid user pmem rss cmd sep
  printf '{"timestamp":"%s","host":"%s","status":"%s","exit_code":%d,' \
    "$timestamp" "$(json_escape "$host")" "$status_text" "$status"
  printf '"thresholds":{"cpu":%s,"mem":%s,"disk":%s,"cpu_crit":%s,"mem_crit":%s,"disk_crit":%s},' \
    "$cpu_warn" "$mem_warn" "$disk_warn" "$cpu_crit" "$mem_crit" "$disk_crit"
  printf '"cpu":{"usage_pct":%s,"cores":%s},' "$cpu_pct" "$cpu_cores"
  printf '"memory":{"usage_pct":%s,"used_kb":%s,"total_kb":%s,"swap_usage_pct":%s},' \
    "$mem_pct" "$mem_used_kb" "$mem_total_kb" "$swap_pct"
  printf '"load":{"1m":%s,"5m":%s,"15m":%s},' "$load1" "$load5" "$load15"
  printf '"disks":['
  sep=""
  for line in "${disk_lines[@]}"; do
    IFS=$'\t' read -r mount fs size used pct <<<"$line"
    printf '%s{"mount":"%s","filesystem":"%s","size_kb":%s,"used_kb":%s,"usage_pct":%s}' \
      "$sep" "$(json_escape "$mount")" "$(json_escape "$fs")" "$size" "$used" "$pct"
    sep=","
  done
  printf '],"top_processes":['
  sep=""
  for line in "${top_procs[@]}"; do
    IFS=$'\t' read -r pid user pmem rss cmd <<<"$line"
    printf '%s{"pid":%s,"user":"%s","mem_pct":%s,"rss_kb":%s,"command":"%s"}' \
      "$sep" "$pid" "$(json_escape "$user")" "$pmem" "$rss" "$(json_escape "$cmd")"
    sep=","
  done
  printf '],"warnings":['
  sep=""
  for line in "${warnings[@]+"${warnings[@]}"}"; do
    printf '%s"%s"' "$sep" "$(json_escape "$line")"
    sep=","
  done
  printf ']}\n'
}

if ! $quiet; then
  if $output_json; then render_json; else render_text; fi
fi
# Warnings always reach stderr too, so cron mail / journald pick them up even with -q.
if $quiet && (( ${#warnings[@]} > 0 )); then
  printf '%s\n' "${warnings[@]}" >&2
fi

# ---------------------------------------------------------- log + rotation ---
rotate_log() {
  local size i
  [[ -f "$log_file" ]] || return 0
  size=$(stat -c %s "$log_file")
  (( size > max_size_kb * 1024 )) || return 0
  rm -f "${log_file}.${keep}"
  for (( i = keep - 1; i >= 1; i-- )); do
    [[ -f "${log_file}.${i}" ]] && mv -f "${log_file}.${i}" "${log_file}.$((i + 1))"
  done
  mv -f "$log_file" "${log_file}.1"
}

write_log() {
  local disk_summary line mount pct
  mkdir -p "$(dirname "$log_file")" || die "cannot create log directory for $log_file"
  # Serialize concurrent runs (cron + manual) so rotation and appends don't interleave.
  exec 9>>"${log_file}.lock" || die "cannot open lock file ${log_file}.lock"
  if command -v flock >/dev/null; then
    flock -w 10 9 || die "timed out waiting for log lock"
  fi
  rotate_log
  if $output_json; then
    render_json >>"$log_file"
  else
    disk_summary=""
    for line in "${disk_lines[@]}"; do
      IFS=$'\t' read -r mount _ _ _ pct <<<"$line"
      disk_summary+="${mount}=${pct}% "
    done
    {
      printf '%s host=%s status=%s cpu=%s%% mem=%s%% load=%s,%s,%s disks=[%s]\n' \
        "$timestamp" "$host" "$status_text" "$cpu_pct" "$mem_pct" "$load1" "$load5" "$load15" "${disk_summary% }"
      for line in "${warnings[@]+"${warnings[@]}"}"; do
        printf '%s   %s\n' "$timestamp" "$line"
      done
    } >>"$log_file"
  fi
}

if $log_enabled; then
  write_log
fi

# ---------------------------------------------------------------- alerting ---
notify() {
  local text payload
  [[ -n "${HEALTH_WEBHOOK_URL:-}" ]] || return 0
  (( status != EXIT_OK )) || return 0
  command -v curl >/dev/null || { echo "$SCRIPT_NAME: curl missing, cannot send webhook" >&2; return 0; }
  text="$(printf '%s %s on %s\n%s' "$status_text" "$timestamp" "$host" "$(printf '%s\n' "${warnings[@]}")")"
  if [[ "$HEALTH_WEBHOOK_URL" == *discord* ]]; then
    payload="{\"content\":\"$(json_escape "$text")\"}"
  else
    payload="{\"text\":\"$(json_escape "$text")\"}"
  fi
  # Alerting must never change the health result: failures are reported, not fatal.
  curl -fsS -m 10 -H 'Content-Type: application/json' -d "$payload" "$HEALTH_WEBHOOK_URL" >/dev/null \
    || echo "$SCRIPT_NAME: webhook delivery failed" >&2
}
notify

trap - ERR
exit "$status"
