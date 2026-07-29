#!/usr/bin/env bash
# Shared helpers: colors, severity tracking, logging, utilities, report file.

SCRIPT_VERSION="${SCRIPT_VERSION:-0.1.0}"

_CHECK_RESULTS=()
_MAX_SEVERITY=0
_JSON_RESULTS=()
REPORT_FILE="${REPORT_FILE:-}"
_RESULTS_FILE=""
_RECORD_LOCK=""
_MAX_SEV_FILE=""

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
  C_MAGENTA=$'\033[35m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

strip_ansi() {
  # shellcheck disable=SC2001
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[[:alpha:]]//g'
}

emit() {
  local line="$1"
  printf '%s\n' "$line"
  if [[ -n "${REPORT_FILE:-}" ]]; then
    strip_ansi "$line" >> "$REPORT_FILE"
    printf '\n' >> "$REPORT_FILE"
  fi
}

log()  { emit "$*"; }
logv() {
  [[ "${VERBOSE:-0}" == "1" ]] || return 0
  local line="${C_DIM}$*${C_RESET}"
  printf '%s\n' "$line" >&2
  if [[ -n "${REPORT_FILE:-}" ]]; then
    strip_ansi "$line" >> "$REPORT_FILE"
    printf '\n' >> "$REPORT_FILE"
  fi
}
loge() {
  local line="${C_RED}$*${C_RESET}"
  printf '%s\n' "$line" >&2
  if [[ -n "${REPORT_FILE:-}" ]]; then
    strip_ansi "$line" >> "$REPORT_FILE"
    printf '\n' >> "$REPORT_FILE"
  fi
}
logi() { emit "${C_CYAN}$*${C_RESET}"; }

_json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

init_result_store() {
  _RESULTS_FILE="$(mktemp "${TMPDIR:-/tmp}/mongoaha-results.XXXXXX")"
  _RECORD_LOCK="$(mktemp "${TMPDIR:-/tmp}/mongoaha-lock.XXXXXX")"
  _MAX_SEV_FILE="$(mktemp "${TMPDIR:-/tmp}/mongoaha-sev.XXXXXX")"
  : > "$_RESULTS_FILE"
  : > "$_RECORD_LOCK"
  : > "${_RESULTS_FILE}.json"
  echo 0 > "$_MAX_SEV_FILE"
}

cleanup_result_store() {
  rm -f "${_RESULTS_FILE:-}" "${_RESULTS_FILE:-}.json" "${_RECORD_LOCK:-}" "${_MAX_SEV_FILE:-}"
}

_CLEANED_UP=0

# Tear down workers + temp state. Safe to call more than once.
cleanup_all() {
  [[ "${_CLEANED_UP}" == "1" ]] && return 0
  _CLEANED_UP=1
  # Stop background checks before removing mux sockets / temp files
  if declare -F kill_parallel_jobs >/dev/null 2>&1; then
    kill_parallel_jobs
  fi
  if declare -F cleanup_ssh_status_store >/dev/null 2>&1; then
    cleanup_ssh_status_store
  fi
  if declare -F cleanup_parallel_store >/dev/null 2>&1; then
    cleanup_parallel_store
  fi
  cleanup_result_store
}

# Ctrl+C / SIGTERM: stop every local worker (and their ssh children) immediately.
on_interrupt() {
  local sig="${1:-INT}"
  _ABORTING=1
  printf '\n' >&2
  loge "Caught ${sig} — stopping all background checks..."
  cleanup_all
  case "$sig" in
    TERM) exit 143 ;;
    *) exit 130 ;;
  esac
}

install_interrupt_traps() {
  _CLEANED_UP=0
  trap 'on_interrupt INT' INT
  trap 'on_interrupt TERM' TERM
  trap 'cleanup_all' EXIT
}

# record_check — flock-safe for parallel workers
record_check() {
  local category="$1" name="$2" status="$3" message="$4" detail="${5-}"
  local sev=0 color="$C_GREEN"
  case "$status" in
    PASS) sev=0; color="$C_GREEN" ;;
    WARN) sev=1; color="$C_YELLOW" ;;
    SLOW) sev=1; color="$C_MAGENTA" ;;
    FAIL) sev=2; color="$C_RED" ;;
    SKIP|INFO) sev=0; color="$C_BLUE" ;;
    *) sev=1; color="$C_YELLOW" ;;
  esac

  local badge line
  printf -v badge '%-4s' "$status"
  line="  ${color}${badge}${C_RESET}  [${category}] ${name} — ${message}"

  _do_write() {
    if [[ -n "${_RESULTS_FILE:-}" ]]; then
      printf '%s\n' "${status}|${category}|${name}|${message}" >> "${_RESULTS_FILE}"
    fi
    if [[ -n "${_MAX_SEV_FILE:-}" ]]; then
      local cur
      cur=$(cat "${_MAX_SEV_FILE}" 2>/dev/null || echo 0)
      if (( sev > cur )); then
        echo "$sev" > "${_MAX_SEV_FILE}"
      fi
    fi
    printf '%s\n' "$line"
    if [[ -n "${REPORT_FILE:-}" ]]; then
      strip_ansi "$line" >> "$REPORT_FILE"
      printf '\n' >> "$REPORT_FILE"
    fi
    if [[ -n "$detail" && "${VERBOSE:-0}" == "1" ]]; then
      local dline="         ${C_DIM}${detail}${C_RESET}"
      printf '%s\n' "$dline"
      if [[ -n "${REPORT_FILE:-}" ]]; then
        strip_ansi "$dline" >> "$REPORT_FILE"
        printf '\n' >> "$REPORT_FILE"
      fi
    fi
    if [[ "${JSON_OUT:-0}" == "1" && -n "${_RESULTS_FILE:-}" ]]; then
      printf '%s\n' "{\"category\":\"$(_json_escape "$category")\",\"name\":\"$(_json_escape "$name")\",\"status\":\"$status\",\"message\":\"$(_json_escape "$message")\",\"detail\":\"$(_json_escape "$detail")\"}" >> "${_RESULTS_FILE}.json"
    fi
  }

  if [[ -n "${_RECORD_LOCK:-}" && -f "${_RECORD_LOCK}" ]]; then
    exec 9>>"${_RECORD_LOCK}"
    flock -x 9
    _do_write
    flock -u 9
    exec 9>&-
  else
    _do_write
  fi
}

load_severity_from_store() {
  if [[ -n "${_MAX_SEV_FILE:-}" && -f "${_MAX_SEV_FILE}" ]]; then
    _MAX_SEVERITY=$(cat "${_MAX_SEV_FILE}")
  fi
}

section() {
  emit ""
  emit "${C_BOLD}== $* ==${C_RESET}"
}

csv_to_array() {
  local -n _out=$1
  local csv="$2"
  _out=()
  local IFS=','
  local item
  for item in $csv; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && _out+=("$item")
  done
}

join_by() {
  local delim="$1"; shift
  local first=1 e
  for e in "$@"; do
    if (( first )); then printf '%s' "$e"; first=0; else printf '%s%s' "$delim" "$e"; fi
  done
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# TCP / telnet-style port probe
tcp_check() {
  local host="$1" port="$2" to="${3:-${TCP_TIMEOUT_SEC:-3}}"
  if have_cmd nc; then
    nc -z -w "$to" "$host" "$port" >/dev/null 2>&1 && return 0
  fi
  if timeout "$to" bash -c "echo >/dev/tcp/${host}/${port}" >/dev/null 2>&1; then
    return 0
  fi
  if have_cmd telnet; then
    timeout "$to" bash -c "printf 'quit\\n' | telnet ${host} ${port} 2>&1" 2>/dev/null | grep -qiE 'Connected|Escape character' && return 0
  fi
  return 1
}

telnet_port_check() {
  local host="$1" port="$2" to="${3:-${TCP_TIMEOUT_SEC:-3}}"
  if have_cmd telnet; then
    timeout "$to" bash -c "printf 'quit\\n' | telnet ${host} ${port} 2>&1" 2>/dev/null | grep -qiE 'Connected|Escape character'
    return $?
  fi
  tcp_check "$host" "$port" "$to"
}

now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null) || { date +%s000; return; }
  if [[ "$ns" =~ ^[0-9]+$ && ${#ns} -gt 10 ]]; then
    printf '%s' "$((ns / 1000000))"
  else
    printf '%s' "$(( $(date +%s) * 1000 ))"
  fi
}

prompt_default() {
  local var_name="$1" prompt="${2-}" default="${3-}"
  local val
  if [[ -z "$var_name" ]]; then
    loge "prompt_default: missing var_name"; return 2
  fi
  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    printf -v "$var_name" '%s' "$default"
    return 0
  fi
  read -r -p "${prompt} [${default}]: " val || true
  if [[ -z "$val" ]]; then
    printf -v "$var_name" '%s' "$default"
  else
    printf -v "$var_name" '%s' "$val"
  fi
}

prompt_secret() {
  local var_name="$1" prompt="${2-}"
  local val
  if [[ -z "$var_name" ]]; then
    loge "prompt_secret: missing var_name"; return 2
  fi
  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    printf -v "$var_name" '%s' ""
    return 0
  fi
  read -r -s -p "${prompt}: " val || true
  printf '\n'
  printf -v "$var_name" '%s' "$val"
}

bytes_human() {
  local b=${1:-0}
  if (( b < 1024 )); then printf '%dB' "$b"
  elif (( b < 1048576 )); then printf '%dKiB' "$((b/1024))"
  elif (( b < 1073741824 )); then printf '%dMiB' "$((b/1048576))"
  else printf '%dGiB' "$((b/1073741824))"
  fi
}

float_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a+0 >= b+0) }'
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# port in CSV list?
port_in_list() {
  local port="$1" csv="$2"
  [[ -z "$csv" ]] && return 1
  printf ',%s,' "$csv" | grep -q ",${port},"
}

is_checker_reachable_port() {
  local port="$1"
  if [[ -n "${CHECKER_REACHABLE_PORTS:-}" ]]; then
    port_in_list "$port" "$CHECKER_REACHABLE_PORTS"
    return $?
  fi
  return 0
}

is_cluster_internal_port() {
  local port="$1"
  port_in_list "$port" "${CLUSTER_INTERNAL_PORTS:-}"
}

init_report_file() {
  local override="${1-}"
  local dir="${REPORT_DIR:-}"
  if [[ -z "$dir" ]]; then
    dir="${ROOT_DIR:-.}/reports"
  fi
  mkdir -p "$dir"
  if [[ -n "$override" ]]; then
    REPORT_FILE="$override"
  else
    local slug
    slug=$(slugify "${CLUSTER_NAME:-cluster}")
    REPORT_FILE="${dir}/mongoaha-${slug}-$(date +%Y%m%d-%H%M%S).log"
  fi
  {
    echo "MongoDB HA Health Check v${SCRIPT_VERSION}"
    echo "Cluster: ${CLUSTER_NAME:-unknown}"
    echo "Config:  ${CONFIG_FILE:-}"
    echo "Started: $(date -Is)"
    echo "----------------------------------------"
  } > "$REPORT_FILE"
  logi "Report file: ${REPORT_FILE}"
}
