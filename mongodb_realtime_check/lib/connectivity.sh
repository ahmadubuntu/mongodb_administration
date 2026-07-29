#!/usr/bin/env bash
# MongoDB cascade: VIP/LB → mongos → mongod (replica set).
# shellcheck shell=bash

_mongo_classify() {
  local msg="$1"
  if echo "$msg" | grep -qiE 'Authentication failed|Unauthorized|not authorized|requires authentication|SCRAM|bad auth|Invalid user'; then
    echo auth
  elif echo "$msg" | grep -qiE 'timed out|Timeout|socket timeout|network timeout'; then
    echo timeout
  elif echo "$msg" | grep -qiE 'Connection refused|No route to host|Network is unreachable|ECONNREFUSED'; then
    echo refused
  elif echo "$msg" | grep -qiE 'SSL|TLS|certificate|handshake|PKIX'; then
    echo tls
  else
    echo other
  fi
}

_mongo_uri_for_target() {
  local target="$1"
  local host="${target%%:*}" port="${target##*:}"
  local user="${MONGO_USER:-}" pass="${MONGO_PASSWORD:-}" authdb="${MONGO_AUTH_DB:-admin}"
  local opts="${MONGO_URI_OPTS:-}"
  if [[ -n "${MONGO_URI:-}" ]]; then
    echo "$MONGO_URI"
    return
  fi
  # Lazy-load from ~/.mongorc.js for this target when needed
  if [[ -z "$user" || -z "$pass" ]]; then
    local f
    for f in "${MONGO_RC_FILE:-}" "${HOME}/.mongorc.js" "${HOME}/.mongoshrc.js"; do
      [[ -n "$f" && -f "$f" ]] || continue
      if declare -F _mongo_creds_from_rc_file >/dev/null 2>&1 && _mongo_creds_from_rc_file "$target" "$f"; then
        user="$MONGO_USER"
        pass="$MONGO_PASSWORD"
        break
      fi
    done
  fi
  local auth="" q="directConnection=true"
  if [[ -n "$user" ]]; then
    local eu ep
    if declare -F _mongo_uri_escape >/dev/null 2>&1; then
      eu="$(_mongo_uri_escape "$user")"
      ep="$(_mongo_uri_escape "$pass")"
    else
      eu="$user"; ep="$pass"
    fi
    auth="${eu}:${ep}@"
    q="authSource=${authdb}&directConnection=true"
  fi
  [[ -n "$opts" ]] && q="${q}&${opts}"
  echo "mongodb://${auth}${host}:${port}/?${q}"
}

_mongo_admin_probe() {
  # Probe with mongosh/mongo hello; fall back to TCP if no local CLI.
  local target="$1"
  local host="${target%%:*}" port="${target##*:}"
  local out rc=0
  local uri
  uri="$(_mongo_uri_for_target "$target")"
  local bin=""
  if have_cmd mongosh; then
    bin="mongosh"
  elif have_cmd mongo; then
    bin="mongo"
  fi

  if [[ -n "$bin" ]]; then
    out="$(timeout "${MONGO_PROBE_TIMEOUT_SEC:-15}" "$bin" --quiet "$uri" --eval 'db.runCommand({hello:1}).ok' 2>&1)" || rc=$?
    echo "$out"
    if [[ $rc -eq 0 ]] && echo "$out" | grep -qE '^1(\.0)?$'; then
      return 0
    fi
    # Some builds print { ok: 1 }
    if [[ $rc -eq 0 ]] && echo "$out" | grep -qE 'ok[[:space:]]*[:=][[:space:]]*1'; then
      return 0
    fi
    return "$rc"
  fi

  if tcp_check "$host" "$port"; then
    echo "TCP_OK ${target} (no local mongosh/mongo — protocol not verified)"
    return 0
  fi
  echo "TCP_FAIL ${target}"
  return 1
}

_cascade_report_failure() {
  local layer="$1" target="$2" msg="$3"
  local cls
  cls="$(_mongo_classify "$msg")"
  case "$cls" in
    auth)
      record_check "cascade" "${layer}|${target}" "WARN" \
        "auth failed from checker — set MONGO_URI or MONGO_USER/MONGO_PASSWORD (or ~/.mongocreds); admin checks can use SSH + mongosh on a member" \
        "$msg"
      ;;
    timeout)
      record_check "cascade" "${layer}|${target}" "FAIL" "timeout talking to ${target}" "$msg"
      ;;
    refused)
      record_check "cascade" "${layer}|${target}" "FAIL" "connection refused on ${target}" "$msg"
      ;;
    tls)
      record_check "cascade" "${layer}|${target}" "WARN" "TLS/SSL error on ${target} — check MONGO_URI_OPTS / tlsCAFile" "$msg"
      ;;
    *)
      record_check "cascade" "${layer}|${target}" "FAIL" "probe failed on ${target}" "$msg"
      ;;
  esac
}

_cascade_tcp_miss() {
  local layer="$1" target="$2" port="$3"
  if is_cluster_internal_port "$port" || ! is_checker_reachable_port "$port"; then
    record_check "cascade" "${layer}|${target}" "INFO" \
      "TCP closed from checker (expected if internal / not in CHECKER_REACHABLE_PORTS)"
  else
    record_check "cascade" "${layer}|${target}" "FAIL" "TCP closed"
  fi
}

_cascade_accept_ssh_admin_path() {
  local layer="$1" target="$2"
  record_check "cascade" "${layer}|${target}" "WARN" \
    "TCP open; auth/protocol not verified from checker — admin path via SSH + mongosh on a member"
  MONGO_CONNECT_OK=1
  MONGO_CONNECT_TARGET="$target"
  _CASCADE_DEPTH="$layer"
  return 0
}

_try_cascade_target() {
  local layer="$1" target="$2" port="$3"
  local out rc=0 cls
  if ! tcp_check "${target%%:*}" "$port"; then
    _cascade_tcp_miss "$layer" "$target" "$port"
    return 1
  fi
  rc=0
  out="$(_mongo_admin_probe "$target")" || rc=$?
  if [[ $rc -eq 0 ]]; then
    if echo "$out" | grep -q 'TCP_OK'; then
      record_check "cascade" "${layer}|${target}" "WARN" \
        "TCP OK but no local mongosh/mongo — protocol/auth not verified; install mongosh or set MONGO_URI"
    else
      record_check "cascade" "${layer}|${target}" "PASS" "client path via ${layer} OK"
    fi
    MONGO_CONNECT_OK=1
    MONGO_CONNECT_TARGET="$target"
    _CASCADE_DEPTH="$layer"
    return 0
  fi
  _cascade_report_failure "$layer" "$target" "$out"
  cls="$(_mongo_classify "$out")"
  if [[ "$cls" == "auth" ]] && _cascade_accept_ssh_admin_path "$layer" "$target"; then
    return 0
  fi
  return 1
}

run_mongo_cascade() {
  section "Client cascade (VIP → LB → mongos → mongod)"
  MONGO_CONNECT_OK=0
  MONGO_CONNECT_TARGET=""
  _CASCADE_DEPTH=""

  # Layer 1: VIP (disabled when VIP_HOST empty)
  if [[ -n "${VIP_HOST:-}" ]]; then
    local vp="${VIP_CLIENT_PORTS:-${MONGO_PORT:-27017}}" p
    for p in $(echo "$vp" | tr ',' ' '); do
      [[ -z "$p" || ! "$p" =~ ^[0-9]+$ ]] && continue
      _try_cascade_target "vip" "${VIP_HOST}:${p}" "$p" && break
    done
  fi

  # Layer 2: LB (disabled when LB_HOSTS empty)
  if [[ "$MONGO_CONNECT_OK" != "1" && -n "${LB_HOSTS:-}" ]]; then
    local lbs=() lp="${LB_CLIENT_PORTS:-${MONGO_PORT:-27017}}" h p
    csv_to_array lbs "${LB_HOSTS}"
    for h in "${lbs[@]}"; do
      for p in $(echo "$lp" | tr ',' ' '); do
        [[ -z "$p" || ! "$p" =~ ^[0-9]+$ ]] && continue
        _try_cascade_target "lb" "${h}:${p}" "$p" && break 2
      done
    done
  fi

  if [[ -z "${VIP_HOST:-}" && -z "${LB_HOSTS:-}" ]]; then
    record_check "cascade" "vip-lb" "INFO" "VIP_HOST/LB_HOSTS empty — cascade starts at mongos/mongod (no VIP/LB checks)"
  fi

  # Layer 3: mongos (sharded)
  if [[ "$MONGO_CONNECT_OK" != "1" && -n "${MONGOS_HOSTS:-}" ]]; then
    local routers=() rp="${MONGOS_PORT:-${MONGO_PORT:-27017}}" h p
    csv_to_array routers "${MONGOS_HOSTS}"
    for h in "${routers[@]}"; do
      for p in $(echo "$rp" | tr ',' ' '); do
        [[ -z "$p" || ! "$p" =~ ^[0-9]+$ ]] && continue
        _try_cascade_target "mongos" "${h}:${p}" "$p" && break 2
      done
    done
  fi

  # Layer 4: direct mongod
  if [[ "$MONGO_CONNECT_OK" != "1" ]]; then
    local nodes=() np="${MONGO_PORT:-27017}" h p
    csv_to_array nodes "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}"
    for h in "${nodes[@]}"; do
      for p in $(echo "$np" | tr ',' ' '); do
        [[ -z "$p" || ! "$p" =~ ^[0-9]+$ ]] && continue
        _try_cascade_target "mongod" "${h}:${p}" "$p" && break 2
      done
    done
  fi

  if [[ "$MONGO_CONNECT_OK" == "1" ]]; then
    case "${_CASCADE_DEPTH}" in
      vip) record_check "cascade" "path" "PASS" "using VIP ${MONGO_CONNECT_TARGET}" ;;
      lb) record_check "cascade" "path" "WARN" "VIP down/missing — using LB ${MONGO_CONNECT_TARGET}" ;;
      mongos)
        if [[ -z "${VIP_HOST:-}" && -z "${LB_HOSTS:-}" ]]; then
          record_check "cascade" "path" "PASS" "direct mongos path (no VIP/LB); target=${MONGO_CONNECT_TARGET}"
        else
          record_check "cascade" "path" "FAIL" "only mongos path works — VIP/LB unavailable; target=${MONGO_CONNECT_TARGET}"
        fi
        ;;
      mongod)
        if [[ -z "${VIP_HOST:-}" && -z "${LB_HOSTS:-}" && -z "${MONGOS_HOSTS:-}" ]]; then
          record_check "cascade" "path" "PASS" \
            "direct mongod path (no VIP/LB/mongos in inventory); target=${MONGO_CONNECT_TARGET}"
        else
          record_check "cascade" "path" "FAIL" \
            "only deep mongod path works — upper layers unavailable; target=${MONGO_CONNECT_TARGET}"
        fi
        ;;
    esac
    if [[ -n "${MONGO_URI:-}" ]]; then
      record_check "cascade" "uri" "INFO" "later checks prefer MONGO_URI from inventory (via local mongosh or SSH)"
    fi
  else
    record_check "cascade" "path" "FAIL" "no client path worked (VIP/LB/mongos/mongod)"
  fi
  export MONGO_CONNECT_OK MONGO_CONNECT_TARGET
}
