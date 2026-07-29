#!/usr/bin/env bash
# Parallel helpers with interruptible fan-out.

_PARALLEL_PID_FILE=""
_ABORTING=0

init_parallel_store() {
  _PARALLEL_PID_FILE="$(mktemp "${TMPDIR:-/tmp}/mongoaha-pids.XXXXXX")"
  : > "${_PARALLEL_PID_FILE}"
  _ABORTING=0
}

cleanup_parallel_store() {
  rm -f "${_PARALLEL_PID_FILE:-}" "${_PARALLEL_PID_FILE:-}.lock"
  _PARALLEL_PID_FILE=""
}

_parallel_track() {
  local pid="$1"
  [[ -z "${_PARALLEL_PID_FILE:-}" || -z "$pid" ]] && return
  {
    flock -x 8
    printf '%s\n' "$pid" >> "${_PARALLEL_PID_FILE}"
  } 8>>"${_PARALLEL_PID_FILE}.lock"
}

_parallel_untrack() {
  local pid="$1"
  [[ -z "${_PARALLEL_PID_FILE:-}" || -z "$pid" || ! -f "${_PARALLEL_PID_FILE}" ]] && return
  {
    flock -x 8
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/mongoaha-pids-edit.XXXXXX")
    grep -vxF "$pid" "${_PARALLEL_PID_FILE}" >"$tmp" 2>/dev/null || true
    mv -f "$tmp" "${_PARALLEL_PID_FILE}"
  } 8>>"${_PARALLEL_PID_FILE}.lock"
}

# Recursively signal a pid and everything under it (ssh → remote bash, etc.).
_kill_tree() {
  local pid="$1" sig="${2:-TERM}" child
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  for child in $(ps -o pid= --ppid "$pid" 2>/dev/null); do
    child="${child// /}"
    [[ -n "$child" ]] && _kill_tree "$child" "$sig"
  done
  if [[ "$pid" != "$$" ]]; then
    kill "-${sig}" "$pid" 2>/dev/null || true
  fi
}

_collect_kill_targets() {
  local pid
  if [[ -n "${_PARALLEL_PID_FILE:-}" && -f "${_PARALLEL_PID_FILE}" ]]; then
    while read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] && printf '%s\n' "$pid"
    done < "${_PARALLEL_PID_FILE}"
  fi
  for pid in $(jobs -pr 2>/dev/null); do
    [[ "$pid" =~ ^[0-9]+$ ]] && printf '%s\n' "$pid"
  done
  for pid in $(ps -o pid= --ppid $$ 2>/dev/null); do
    pid="${pid// /}"
    [[ -n "$pid" && "$pid" != "$$" ]] && printf '%s\n' "$pid"
  done
}

# Kill every tracked worker and any remaining children of this shell.
# Background workers ignore SIGINT from the terminal, so we must TERM/KILL them.
kill_parallel_jobs() {
  local pid targets
  targets=$(_collect_kill_targets | sort -u) || true

  for pid in $targets; do
    _kill_tree "$pid" TERM
  done

  # Brief grace, then KILL anything still alive so wait cannot hang.
  sleep 0.15
  for pid in $targets; do
    if kill -0 "$pid" 2>/dev/null; then
      _kill_tree "$pid" KILL
    fi
  done

  if [[ -n "${_PARALLEL_PID_FILE:-}" ]]; then
    : > "${_PARALLEL_PID_FILE}"
  fi

  # Reap without blocking forever: each wait is best-effort.
  for pid in $targets; do
    wait "$pid" 2>/dev/null || true
  done
}

run_parallel_fn() {
  local fn="$1"; shift
  local max="${PARALLEL_JOBS:-8}"
  local pids=() arg n=0 pid

  if [[ "${_ABORTING:-0}" == "1" ]]; then
    return 130
  fi

  for arg in "$@"; do
    if [[ "${_ABORTING:-0}" == "1" ]]; then
      kill_parallel_jobs
      return 130
    fi
    "$fn" "$arg" &
    pid=$!
    pids+=("$pid")
    _parallel_track "$pid"
    n=$((n + 1))
    if (( n >= max )); then
      wait "${pids[0]}" 2>/dev/null || true
      _parallel_untrack "${pids[0]}"
      pids=("${pids[@]:1}")
      n=$((n - 1))
    fi
  done
  for pid in "${pids[@]:-}"; do
    if [[ "${_ABORTING:-0}" == "1" ]]; then
      kill_parallel_jobs
      return 130
    fi
    wait "$pid" 2>/dev/null || true
    _parallel_untrack "$pid"
  done

  if [[ "${_ABORTING:-0}" == "1" ]]; then
    return 130
  fi
}

# resolve_parallel_jobs [n_items]
# Sets PARALLEL_JOBS from JOBS_ARG or inventory PARALLEL_JOBS (default 8).
resolve_parallel_jobs() {
  local _n="${1:-0}"
  case "${JOBS_ARG:-}" in
    ""|auto)
      PARALLEL_JOBS="${PARALLEL_JOBS:-8}"
      ;;
    ask)
      if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        PARALLEL_JOBS="${PARALLEL_JOBS:-8}"
      else
        local ans suggested="${PARALLEL_JOBS:-8}"
        read -r -p "Parallel jobs [${suggested}]: " ans || true
        if [[ -z "$ans" ]]; then
          PARALLEL_JOBS="$suggested"
        elif [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= 64 )); then
          PARALLEL_JOBS="$ans"
        else
          loge "--jobs must be an integer 1–64"; exit 2
        fi
      fi
      ;;
    *)
      if [[ "${JOBS_ARG}" =~ ^[0-9]+$ ]] && (( JOBS_ARG >= 1 && JOBS_ARG <= 64 )); then
        PARALLEL_JOBS="$JOBS_ARG"
      else
        loge "--jobs must be ask, auto, or integer 1–64"; exit 2
      fi
      ;;
  esac
  export PARALLEL_JOBS
}
