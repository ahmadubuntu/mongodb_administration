#!/usr/bin/env bash
# Generic remote systemd / process helpers.

check_systemd_active() {
  local host="$1" service="$2" label="${3:-$service@$host}"
  local out rc=0
  out=$(remote_run "$host" 0 "systemctl is-active ${service} 2>/dev/null || echo inactive" 2>&1) || rc=$?
  out=$(echo "$out" | tr -d '\r' | tail -n1)
  if [[ "$out" == "active" ]]; then
    record_check "service" "$label" "PASS" "${service} is active"
  elif [[ "$out" == "inactive" || "$out" == "failed" ]]; then
    # retry with sudo in case of permission
    out=$(remote_run "$host" 1 "systemctl is-active ${service} 2>/dev/null || echo inactive" 2>&1 | tr -d '\r' | tail -n1) || true
    if [[ "$out" == "active" ]]; then
      record_check "service" "$label" "PASS" "${service} is active"
    else
      record_check "service" "$label" "FAIL" "${service} is ${out:-unknown}"
    fi
  else
    record_check "service" "$label" "WARN" "${service} state: ${out}"
  fi
}

check_systemd_failed() {
  local host="$1" label="${2:-failed@$host}"
  local out units
  out=$(remote_run "$host" 0 "systemctl --failed --no-legend --no-pager 2>/dev/null | head -20" 2>&1) || true
  if [[ -z "${out// }" ]]; then
    record_check "service" "$label" "PASS" "No failed systemd units"
    return
  fi
  # Name the units — "failed units present" alone hides things like pgbackrest.service
  units=$(printf '%s\n' "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /\.(service|timer|mount|socket)$/) {print $i; break}}' | paste -sd' ' -)
  record_check "service" "$label" "WARN" "Failed units: ${units:-see detail}" "$out"
}

check_process_running() {
  local host="$1" pattern="$2" label="$3"
  local out
  out=$(remote_run "$host" 0 "pgrep -a ${pattern} 2>/dev/null | head -5" 2>&1) || true
  if [[ -n "$out" ]]; then
    record_check "process" "$label" "PASS" "Process matching '${pattern}' found"
  else
    record_check "process" "$label" "FAIL" "No process matching '${pattern}'"
  fi
}
