#!/usr/bin/env bash
# SSH helpers: telnet/TCP preflight, slow detection, sudo once, DB password once.

SSH_USER=""
SUDO_PASSWORD=""
USE_SUDO=1
PGPASSWORD_PROMPTED=0
CREDENTIALS_DONE=0
_SSH_OK_FILE=""
_SSH_NOMUX_FILE=""
_SSH_CTRL_DIR=""

init_ssh_status_store() {
  _SSH_OK_FILE="$(mktemp "${TMPDIR:-/tmp}/mongoaha-sshok.XXXXXX")"
  : > "$_SSH_OK_FILE"
  _SSH_NOMUX_FILE="$(mktemp "${TMPDIR:-/tmp}/mongoaha-sshnomux.XXXXXX")"
  : > "$_SSH_NOMUX_FILE"
  # Multiplex SSH: one master per host, reused by later remote_run / port-cross probes
  _SSH_CTRL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mongoaha-sshctrl.XXXXXX")"
  chmod 700 "$_SSH_CTRL_DIR"
}

cleanup_ssh_status_store() {
  if [[ -n "${_SSH_CTRL_DIR:-}" && -d "${_SSH_CTRL_DIR}" ]]; then
    # Close masters cleanly
    local sock
    for sock in "${_SSH_CTRL_DIR}"/ctrl-*; do
      [[ -e "$sock" ]] || continue
      ssh -O exit -o "ControlPath=${sock}" unused 2>/dev/null || true
    done
    rm -rf "${_SSH_CTRL_DIR}"
  fi
  rm -f "${_SSH_OK_FILE:-}" "${_SSH_OK_FILE:-}.lock" \
        "${_SSH_NOMUX_FILE:-}" "${_SSH_NOMUX_FILE:-}.lock"
}

ssh_host_is_ok() {
  local host="$1"
  [[ -n "${_SSH_OK_FILE:-}" && -f "${_SSH_OK_FILE}" ]] || return 1
  grep -qxF "$host" "${_SSH_OK_FILE}" 2>/dev/null
}

mark_ssh_ok() {
  local host="$1"
  [[ -z "${_SSH_OK_FILE:-}" ]] && return
  {
    flock -x 8
    grep -qxF "$host" "${_SSH_OK_FILE}" 2>/dev/null || printf '%s\n' "$host" >> "${_SSH_OK_FILE}"
  } 8>>"${_SSH_OK_FILE}.lock"
}

ssh_ctrl_path() {
  local host="$1"
  printf '%s/ctrl-%s' "${_SSH_CTRL_DIR:-/tmp}" "${host//[^a-zA-Z0-9._-]/_}"
}

ssh_mux_disabled() {
  local host="$1"
  [[ -n "${_SSH_NOMUX_FILE:-}" && -f "${_SSH_NOMUX_FILE}" ]] || return 1
  grep -qxF "$host" "${_SSH_NOMUX_FILE}" 2>/dev/null
}

mark_ssh_nomux() {
  local host="$1"
  [[ -z "${_SSH_NOMUX_FILE:-}" ]] && return
  {
    flock -x 8
    grep -qxF "$host" "${_SSH_NOMUX_FILE}" 2>/dev/null || printf '%s\n' "$host" >> "${_SSH_NOMUX_FILE}"
  } 8>>"${_SSH_NOMUX_FILE}.lock"
}

ssh_base_opts() {
  local to="${1:-${SSH_TIMEOUT_SEC:-12}}"
  local host="${2-}"
  local opts="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=${to} -o ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL:-5} -o LogLevel=ERROR -p ${SSH_PORT:-22}"
  if [[ -n "${_SSH_CTRL_DIR:-}" && -n "$host" ]] && ! ssh_mux_disabled "$host"; then
    opts+=" -o ControlMaster=auto -o ControlPersist=${SSH_CONTROL_PERSIST_SEC:-120} -o ControlPath=$(ssh_ctrl_path "$host")"
  else
    opts+=" -o ControlMaster=no -o ControlPath=none"
  fi
  printf '%s' "$opts"
}

# _ssh_exec HOST TIMEOUT PAYLOAD [STDIN_DATA]
# Runs PAYLOAD over SSH, keeping stdout clean for the caller. Multiplexing breaks on
# hosts whose session setup blocks (e.g. systemd-logind down, so pam_systemd waits out
# its 25s D-Bus timeout); when that happens the mux client dies with "Failed to connect
# to new control master". Retry once without multiplexing and stop multiplexing to that
# host for the rest of the run, instead of declaring the host unreachable.
_ssh_exec() {
  local host="$1" to="$2" payload="$3" stdin_data="${4-}"
  local errf rc=0
  errf=$(mktemp "${TMPDIR:-/tmp}/mongoaha-ssherr.XXXXXX")

  if [[ -n "$stdin_data" ]]; then
    # shellcheck disable=SC2086
    printf '%s\n' "$stdin_data" | ssh $(ssh_base_opts "$to" "$host") "${SSH_USER}@${host}" "$payload" 2>"$errf" || rc=$?
  else
    # shellcheck disable=SC2086
    ssh $(ssh_base_opts "$to" "$host") "${SSH_USER}@${host}" "$payload" 2>"$errf" || rc=$?
  fi

  if [[ $rc -ne 0 ]] && grep -qEi 'mux_client|control master|control socket|multiplex' "$errf" 2>/dev/null; then
    mark_ssh_nomux "$host"
    logv "SSH multiplexing failed for ${host}; retrying without ControlMaster"
    rc=0
    local plain="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=${to} -o ServerAliveInterval=5 -o LogLevel=ERROR -o ControlMaster=no -o ControlPath=none -p ${SSH_PORT:-22}"
    if [[ -n "$stdin_data" ]]; then
      # shellcheck disable=SC2086
      printf '%s\n' "$stdin_data" | ssh $plain "${SSH_USER}@${host}" "$payload" 2>"$errf" || rc=$?
    else
      # shellcheck disable=SC2086
      ssh $plain "${SSH_USER}@${host}" "$payload" 2>"$errf" || rc=$?
    fi
  fi

  cat "$errf" >&2
  rm -f "$errf"
  return $rc
}

remote_run() {
  local host="$1"
  local need_sudo="$2"
  shift 2
  local cmd="$*"
  local to="${SSH_TIMEOUT_SEC:-12}"

  if [[ "$need_sudo" != "1" || "${USE_SUDO}" != "1" ]]; then
    _ssh_exec "$host" "$to" "bash -lc $(printf '%q' "$cmd")"
    return $?
  fi

  if [[ -z "${SUDO_PASSWORD}" ]]; then
    _ssh_exec "$host" "$to" "bash -lc $(printf '%q' "sudo -n bash -lc $(printf '%q' "$cmd")")"
    return $?
  fi

  _ssh_exec "$host" "$to" \
    "read -r __pw; printf '%s\n' \"\$__pw\" | sudo -S -p '' bash -lc $(printf '%q' "$cmd")" \
    "$SUDO_PASSWORD"
}

# Timed SSH with optional timeout override; sets SSH_LAST_MS / SSH_LAST_OUT
ssh_timed() {
  local host="$1"
  local to="$2"
  shift 2
  local cmd="$*"
  local start end rc=0
  start=$(now_ms)
  # shellcheck disable=SC2086
  SSH_LAST_OUT=$(ssh $(ssh_base_opts "$to" "$host") "${SSH_USER}@${host}" "bash -lc $(printf '%q' "$cmd")" 2>&1) || rc=$?
  end=$(now_ms)
  SSH_LAST_MS=$((end - start))
  if (( SSH_LAST_MS < 0 )); then SSH_LAST_MS=0; fi
  return $rc
}

check_ssh_host() {
  local host="$1"
  local label="${2:-$host}"
  local warn_ms="${SSH_SLOW_WARN_MS:-3000}"
  local port="${SSH_PORT:-22}"
  local rc=0
  local out ms

  # Some modules re-probe hosts the connectivity section already cleared. Trust the
  # earlier result: one flaky telnet attempt should not turn a working host into a
  # FAIL halfway through the report.
  if ssh_host_is_ok "$host"; then
    record_check "ssh" "$label" "PASS" "already verified earlier in this run"
    return 0
  fi

  # 1) Port preflight: telnet first, then plain TCP with a growing timeout. A single
  # telnet probe fired at every host at once gives false negatives, and a false
  # negative here skips every other check for that host.
  local attempt open=0 method=""
  for attempt in 1 2 3; do
    if [[ "$attempt" == "1" ]]; then
      if telnet_port_check "$host" "$port" "${TCP_TIMEOUT_SEC:-3}"; then
        open=1
        method="telnet"
      fi
    else
      sleep 1
      if tcp_check "$host" "$port" "$(( ${TCP_TIMEOUT_SEC:-3} * attempt ))"; then
        open=1
        method="tcp attempt ${attempt}"
      fi
    fi
    if [[ "$open" == "1" ]]; then break; fi
  done
  if [[ "$open" == "1" ]]; then
    record_check "ssh-port" "${label}|${port}" "PASS" "SSH port open (${method})"
  else
    record_check "ssh-port" "${label}|${port}" "FAIL" "SSH port closed/unreachable (telnet + 2 TCP attempts)"
    record_check "ssh" "$label" "FAIL" "skip SSH — port ${port} not open"
    return 0
  fi

  # 2) SSH with normal timeout
  ssh_timed "$host" "${SSH_TIMEOUT_SEC:-12}" "hostname -f 2>/dev/null || hostname; whoami" || rc=$?
  out="${SSH_LAST_OUT//$'\n'/; }"
  ms="${SSH_LAST_MS:-0}"

  if [[ $rc -ne 0 ]]; then
    # 3) Port was open → raise timeout and retry once
    local retry_to="${SSH_RETRY_TIMEOUT_SEC:-35}"
    record_check "ssh" "$label" "WARN" "SSH failed in ${ms}ms with timeout=${SSH_TIMEOUT_SEC:-12}s; retrying with ${retry_to}s"
    rc=0
    ssh_timed "$host" "$retry_to" "hostname -f 2>/dev/null || hostname; whoami" || rc=$?
    out="${SSH_LAST_OUT//$'\n'/; }"
    ms="${SSH_LAST_MS:-0}"
    if [[ $rc -ne 0 ]]; then
      record_check "ssh" "$label" "FAIL" "unreachable after retry (${ms}ms, to=${retry_to}s) — ${out}"
      return 0
    fi
  fi

  mark_ssh_ok "$host"
  if (( ms >= warn_ms )); then
    record_check "ssh" "$label" "SLOW" "connected but slow: ${ms}ms (warn>=${warn_ms}ms) — ${out}"
  else
    record_check "ssh" "$label" "PASS" "OK in ${ms}ms — ${out}"
  fi
  return 0
}

prompt_credentials() {
  if [[ -n "${SSH_USER_OVERRIDE:-}" ]]; then
    SSH_USER="$SSH_USER_OVERRIDE"
  elif [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    SSH_USER="${SSH_USER:-$USER}"
  else
    prompt_default SSH_USER "SSH username" "${SSH_USER:-$USER}"
  fi
  export SSH_USER

  if [[ "${USE_SUDO:-1}" == "1" ]]; then
    if [[ -n "${SUDO_PASSWORD_ENV:-}" ]]; then
      SUDO_PASSWORD="$SUDO_PASSWORD_ENV"
    elif [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
      prompt_secret SUDO_PASSWORD "sudo password (empty = passwordless sudo -n)"
    fi
    export SUDO_PASSWORD
  fi
}

