#!/usr/bin/env bash
# MongoDB capacity: FD / connections / WiredTiger cache / narrowest layer.
# shellcheck shell=bash

_check_mongo_fd_limits() {
  local host="$1"
  local unit="${MONGOD_SYSTEMD_UNIT:-mongod}"
  local out soft hard open="" limit
  out="$(remote_run "$host" 1 "systemctl show ${unit} -p LimitNOFILE --value 2>/dev/null; MAIN=\$(systemctl show -p MainPID --value ${unit}); if [[ -n \$MAIN && \$MAIN != 0 ]]; then awk '/Max open files/{print \$4,\$5}' /proc/\$MAIN/limits; ls /proc/\$MAIN/fd 2>/dev/null | wc -l; fi" 2>&1)" || true
  limit="$(echo "$out" | head -1 | tr -d '\r')"
  soft="$(echo "$out" | awk 'NR==2{print $1}')"
  hard="$(echo "$out" | awk 'NR==2{print $2}')"
  open="$(echo "$out" | awk 'NR==3{print $1}')"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit="${hard:-${soft:-0}}"
  [[ "$open" =~ ^[0-9]+$ ]] || open=0
  if [[ "${limit:-0}" -le 0 ]]; then
    record_check "capacity" "fd:${host}" "SKIP" "LimitNOFILE unavailable for ${unit}"
    return
  fi
  local pct=$(( open * 100 / limit ))
  local detail="open=${open} LimitNOFILE=${limit} (ulimit soft/hard ${soft:-?}/${hard:-?}) — unit=${unit}; raise via /etc/systemd/system/${unit}.service.d/override.conf then systemctl daemon-reload && systemctl restart ${unit}"
  if (( pct >= ${CONN_FAIL_PCT:-90} )); then
    record_check "capacity" "fd:${host}" "FAIL" "${pct}% FD used — ${detail}"
  elif (( pct >= ${CONN_WARN_PCT:-70} )); then
    record_check "capacity" "fd:${host}" "WARN" "${pct}% FD used — ${detail}"
  else
    record_check "capacity" "fd:${host}" "PASS" "${pct}% FD used (open=${open}/${limit})"
  fi
}

_check_mongo_connections() {
  local host="$1"
  local port="${MONGO_PORT:-27017}"
  local count
  count="$(remote_run "$host" 0 "ss -tn state established \"( sport = :${port} )\" 2>/dev/null | tail -n +2 | wc -l" 2>&1)" || count=0
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  record_check "capacity" "conn:${host}:${port}" "INFO" "established=${count}"

  local ceil="${CONN_SOFT_CEILING:-${MONGO_CONN_CEILING:-}}"
  # Prefer live maxIncomingConnections from serverStatus when we can eval on host
  local maxc=""
  maxc="$(_mongo_eval_on_host "$host" 'db.serverStatus().connections.available+db.serverStatus().connections.current' 2>/dev/null)" || true
  if [[ "$maxc" =~ ^[0-9]+$ && "$maxc" -gt 0 ]]; then
    ceil="$maxc"
  fi
  [[ -z "$ceil" ]] && ceil=2000

  local current=""
  current="$(_mongo_eval_on_host "$host" 'db.serverStatus().connections.current' 2>/dev/null)" || true
  [[ "$current" =~ ^[0-9]+$ ]] || current="$count"

  local pct=0
  if [[ "$ceil" -gt 0 ]]; then
    pct=$(( current * 100 / ceil ))
  fi
  local msg="connections=${current} vs limit≈${ceil} (~${pct}%); tune net.maxIncomingConnections in ${MONGO_CONF:-/etc/mongod.conf} then restart ${MONGOD_SYSTEMD_UNIT:-mongod}"
  if (( pct >= ${CONN_FAIL_PCT:-90} )); then
    record_check "capacity" "connections:${host}" "FAIL" "$msg"
  elif (( pct >= ${CONN_WARN_PCT:-70} )); then
    record_check "capacity" "connections:${host}" "WARN" "$msg"
  else
    record_check "capacity" "connections:${host}" "PASS" "$msg"
  fi
}

_check_mongo_wiredtiger() {
  local host="$1"
  local dirty max_dirty
  dirty="$(_mongo_eval_on_host "$host" 'var c=db.serverStatus().wiredTiger.cache; print(c["tracked dirty bytes in the cache"]||0)' 2>/dev/null)" || true
  max_dirty="$(_mongo_eval_on_host "$host" 'var c=db.serverStatus().wiredTiger.cache; print(c["maximum bytes configured"]||0)' 2>/dev/null)" || true
  if [[ ! "$dirty" =~ ^[0-9]+$ || ! "$max_dirty" =~ ^[0-9]+$ || "$max_dirty" -le 0 ]]; then
    record_check "capacity" "wt-cache:${host}" "SKIP" "WiredTiger cache stats unavailable"
    return
  fi
  local pct=$(( dirty * 100 / max_dirty ))
  local msg="WT dirty≈${pct}% (dirty=${dirty} / max=${max_dirty}) — storage.wiredTiger.engineConfig.cacheSizeGB in ${MONGO_CONF:-/etc/mongod.conf}"
  if (( pct >= ${WT_DIRTY_FAIL_PCT:-80} )); then
    record_check "capacity" "wt-cache:${host}" "FAIL" "$msg"
  elif (( pct >= ${WT_DIRTY_WARN_PCT:-50} )); then
    record_check "capacity" "wt-cache:${host}" "WARN" "$msg"
  else
    record_check "capacity" "wt-cache:${host}" "PASS" "$msg"
  fi
}

check_mongo_capacity() {
  section "Capacity (FD / connections / WiredTiger)"
  local hosts=() h seen="|"
  local role_hosts arr
  for role_hosts in "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}" "${CONFIGSVR_HOSTS:-}"; do
    arr=()
    csv_to_array arr "$role_hosts"
    for h in "${arr[@]}"; do
      [[ -z "$h" || "$seen" == *"|${h}|"* ]] && continue
      seen+="${h}|"
      hosts+=("$h")
    done
  done
  if [[ ${#hosts[@]} -eq 0 ]]; then
    record_check "capacity" "hosts" "SKIP" "MONGOD_HOSTS empty"
    return
  fi
  for h in "${hosts[@]}"; do
    if ! ssh_host_is_ok "$h"; then
      record_check "capacity" "${h}" "SKIP" "SSH unavailable"
      continue
    fi
    _check_mongo_fd_limits "$h"
    _check_mongo_connections "$h"
    _check_mongo_wiredtiger "$h"
  done

  record_check "capacity" "narrowest" "INFO" \
    "Typical narrowest layers: net.maxIncomingConnections → LimitNOFILE → WT cache → disk on dbPath. Tune: ${MONGO_CONF:-/etc/mongod.conf}; systemd override for LimitNOFILE."
}

check_vip_owner() {
  [[ -n "${VIP_HOST:-}" ]] || return 0
  section "VIP ownership"
  local holders=() hosts=() h
  csv_to_array hosts "${LB_HOSTS:-${MONGOS_HOSTS:-${MONGOD_HOSTS:-${MONGO_HOSTS:-}}}}"
  for h in "${hosts[@]}"; do
    ssh_host_is_ok "$h" || continue
    if remote_run "$h" 0 "ip -4 addr show | grep -q '[ /]${VIP_HOST}/'" 2>/dev/null; then
      holders+=("$h")
    fi
  done
  case "${#holders[@]}" in
    0) record_check "vip" "owner" "FAIL" "no node holds VIP ${VIP_HOST}" ;;
    1) record_check "vip" "owner" "PASS" "VIP ${VIP_HOST} held by ${holders[0]}" ;;
    *) record_check "vip" "owner" "FAIL" "split-brain: VIP on ${holders[*]}" ;;
  esac
}
