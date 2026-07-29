#!/usr/bin/env bash
# Port matrix: local / listen / cross — only inventory ports; cluster-internal local miss = INFO.
# shellcheck shell=bash

remote_is_listening() {
  local host="$1" port="$2"
  local out
  out=$(remote_run "$host" 0 "ss -lntu 2>/dev/null | awk '{print \$5}' | grep -E '[:.]${port}\$' | head -1" 2>/dev/null) || true
  [[ -n "${out// }" ]] && return 0
  out=$(remote_run "$host" 1 "ss -lntu 2>/dev/null | awk '{print \$5}' | grep -E '[:.]${port}\$' | head -1" 2>/dev/null) || true
  [[ -n "${out// }" ]]
}

remote_tcp_from() {
  local src="$1" dest="$2" port="$3"
  local to="${TCP_TIMEOUT_SEC:-3}"
  local out rc=0
  out=$(remote_run "$src" 0 "if command -v nc >/dev/null 2>&1; then nc -z -w ${to} ${dest} ${port}; else timeout ${to} bash -c 'echo >/dev/tcp/${dest}/${port}'; fi; echo RC=\$?" 2>&1) || rc=$?
  if printf '%s' "$out" | grep -q 'RC=0'; then
    return 0
  fi
  return 1
}

check_port_triple() {
  local role="$1" host="$2" port="$3"
  local local_ok=0 listen_ok=0
  [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] || return 0

  if tcp_check "$host" "$port"; then
    local_ok=1
    record_check "port-local" "${role}|${host}|${port}" "PASS" "reachable from checker"
  else
    if is_cluster_internal_port "$port" || ! is_checker_reachable_port "$port"; then
      record_check "port-local" "${role}|${host}|${port}" "INFO" "not reachable from checker (cluster-internal / not in CHECKER_REACHABLE_PORTS)"
    else
      record_check "port-local" "${role}|${host}|${port}" "FAIL" "not reachable from checker"
    fi
  fi

  if ! ssh_host_is_ok "$host"; then
    record_check "port-listen" "${role}|${host}|${port}" "SKIP" "SSH unavailable — listen not checked"
  elif remote_is_listening "$host" "$port"; then
    listen_ok=1
    record_check "port-listen" "${role}|${host}|${port}" "PASS" "listening on host"
  else
    record_check "port-listen" "${role}|${host}|${port}" "FAIL" "not listening on host"
  fi

  if [[ $local_ok -eq 1 && $listen_ok -eq 0 ]] && ssh_host_is_ok "$host"; then
    record_check "port-consistency" "${role}|${host}|${port}" "WARN" "reachable locally but not listening on host"
  elif [[ $local_ok -eq 0 && $listen_ok -eq 1 ]]; then
    if is_cluster_internal_port "$port" || ! is_checker_reachable_port "$port"; then
      record_check "port-consistency" "${role}|${host}|${port}" "INFO" "listening on host; blocked from checker (expected if internal)"
    else
      record_check "port-consistency" "${role}|${host}|${port}" "WARN" "listening on host but not reachable from checker"
    fi
  fi
}

_check_ports_one_host() {
  local host="$1" ports=() p
  csv_to_array ports "${_CP_PORTS_CSV}"
  for p in "${ports[@]}"; do
    check_port_triple "${_CP_ROLE}" "$host" "$p"
  done
}

check_ports_for_role() {
  local role="$1" hosts_csv="$2" ports_csv="$3"
  local hosts=() ports=() uniq=() p seen="|"
  csv_to_array hosts "$hosts_csv"
  csv_to_array ports "$ports_csv"
  for p in "${ports[@]}"; do
    [[ -z "$p" || ! "$p" =~ ^[0-9]+$ ]] && continue
    [[ "$seen" == *"|${p}|"* ]] && continue
    seen+="${p}|"
    uniq+=("$p")
  done
  (( ${#uniq[@]} > 0 )) || return 0
  _CP_ROLE="$role"
  _CP_PORTS_CSV="$(join_by ',' "${uniq[@]}")"
  run_parallel_fn _check_ports_one_host "${hosts[@]}"
}

check_cross_mesh() {
  local service="$1" hosts_csv="$2" ports_csv="$3"
  local hosts=() ports=() src
  csv_to_array hosts "$hosts_csv"
  csv_to_array ports "$ports_csv"
  [[ ${#ports[@]} -eq 0 ]] && return
  if [[ ${#hosts[@]} -lt 2 ]]; then
    record_check "port-cross" "${service}" "SKIP" "need >=2 hosts for mesh"
    return
  fi

  emit "  ${C_DIM}mesh ${service}: $(join_by ' ↔ ' "${hosts[@]}") ports=$(join_by , "${ports[@]}")${C_RESET}"

  _cross_one_src() {
    local src="$1" dst p
    if ! ssh_host_is_ok "$src"; then
      record_check "port-cross" "${service}|from:${src}" "SKIP" "SSH down — mesh from this node skipped"
      return
    fi
    for dst in "${hosts[@]}"; do
      [[ "$src" == "$dst" ]] && continue
      for p in "${ports[@]}"; do
        if remote_tcp_from "$src" "$dst" "$p"; then
          record_check "port-cross" "${service}|${src}→${dst}|${p}" "PASS" "peer path open"
        else
          record_check "port-cross" "${service}|${src}→${dst}|${p}" "FAIL" "peer path closed/filtered"
        fi
      done
    done
  }

  run_parallel_fn _cross_one_src "${hosts[@]}"
}

run_port_matrix() {
  section "Port matrix (local / listen / cross)"
  emit "  ${C_DIM}local=from checker; listen=ss on host; cross=peer mesh via SSH${C_RESET}"

  local mongods=() mongos=() configsvr=() lb=()
  csv_to_array mongods "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}"
  csv_to_array mongos "${MONGOS_HOSTS:-}"
  csv_to_array configsvr "${CONFIGSVR_HOSTS:-}"
  csv_to_array lb "${LB_HOSTS:-}"

  local mongod_ports="${MONGO_PORT:-27017},${MONGO_PORTS:-},${MONGO_ADMIN_PORTS:-}"
  local mongos_ports="${MONGOS_PORT:-${MONGO_PORT:-27017}},${MONGOS_PORTS:-}"
  local config_ports="${CONFIGSVR_PORT:-27019},${CONFIGSVR_PORTS:-}"

  if [[ ${#mongods[@]} -gt 0 ]]; then
    check_ports_for_role "mongod" "${MONGOD_HOSTS:-${MONGO_HOSTS}}" "$mongod_ports"
  fi
  if [[ ${#mongos[@]} -gt 0 ]]; then
    check_ports_for_role "mongos" "${MONGOS_HOSTS}" "$mongos_ports"
  fi
  if [[ ${#configsvr[@]} -gt 0 ]]; then
    check_ports_for_role "configsvr" "${CONFIGSVR_HOSTS}" "$config_ports"
  fi

  if [[ ${#lb[@]} -gt 0 ]]; then
    check_ports_for_role "lb" "${LB_HOSTS}" "${LB_CLIENT_PORTS:-${MONGO_PORT:-27017}}"
  fi
  if [[ -n "${VIP_HOST:-}" ]]; then
    local p
    for p in $(echo "${VIP_CLIENT_PORTS:-${MONGO_PORT:-27017}}" | tr ',' ' '); do
      [[ -z "$p" || ! "$p" =~ ^[0-9]+$ ]] && continue
      if tcp_check "$VIP_HOST" "$p"; then
        if is_checker_reachable_port "$p"; then
          record_check "port-local" "vip|${VIP_HOST}|${p}" "PASS" "reachable from checker"
        else
          record_check "port-local" "vip|${VIP_HOST}|${p}" "INFO" "reachable (not in CHECKER_REACHABLE_PORTS)"
        fi
      else
        if is_checker_reachable_port "$p"; then
          record_check "port-local" "vip|${VIP_HOST}|${p}" "FAIL" "not reachable from checker"
        elif is_cluster_internal_port "$p"; then
          record_check "port-local" "vip|${VIP_HOST}|${p}" "INFO" "not reachable from checker (cluster-internal)"
        else
          record_check "port-local" "vip|${VIP_HOST}|${p}" "WARN" "not reachable from checker"
        fi
      fi
    done
  fi

  section "Cross-node mongod / configsvr mesh"
  local mesh_ports="${MONGO_PORT:-27017}"
  [[ -n "${MONGO_PORTS:-}" ]] && mesh_ports="${mesh_ports},${MONGO_PORTS}"
  if [[ ${#mongods[@]} -gt 1 ]]; then
    check_cross_mesh "mongod" "${MONGOD_HOSTS:-${MONGO_HOSTS}}" "$mesh_ports"
  elif [[ ${#mongods[@]} -le 1 ]]; then
    record_check "port-cross" "mongod-mesh" "INFO" "single mongod — replica mesh N/A"
  fi
  if [[ ${#configsvr[@]} -gt 1 ]]; then
    check_cross_mesh "configsvr" "${CONFIGSVR_HOSTS}" "${CONFIGSVR_PORT:-27019}"
  fi

  # LB → backends (mongos preferred, else mongod)
  local backends=() backend_csv="" backend_ports=""
  if [[ ${#mongos[@]} -gt 0 ]]; then
    backends=("${mongos[@]}")
    backend_csv="${MONGOS_HOSTS}"
    backend_ports="${LB_BACKEND_PORTS:-${MONGOS_PORT:-${MONGO_PORT:-27017}}}"
  elif [[ ${#mongods[@]} -gt 0 ]]; then
    backends=("${mongods[@]}")
    backend_csv="${MONGOD_HOSTS:-${MONGO_HOSTS}}"
    backend_ports="${LB_BACKEND_PORTS:-${MONGO_PORT:-27017}}"
  fi
  if [[ ${#lb[@]} -gt 0 && ${#backends[@]} -gt 0 ]]; then
    section "Cross path LB → mongo backends"
    local client_ports=()
    csv_to_array client_ports "$backend_ports"
    _lb_to_mongo() {
      local h="$1" b port
      if ! ssh_host_is_ok "$h"; then
        record_check "port-cross" "lb→mongo|from:${h}" "SKIP" "SSH down on LB — cannot probe from it"
        return
      fi
      for b in "${backends[@]}"; do
        for port in "${client_ports[@]}"; do
          [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] && continue
          if remote_tcp_from "$h" "$b" "$port"; then
            record_check "port-cross" "lb→mongo|${h}→${b}|${port}" "PASS" "from ${h}: ${b}:${port} OK"
          else
            record_check "port-cross" "lb→mongo|${h}→${b}|${port}" "FAIL" "from ${h}: ${b}:${port} failed"
          fi
        done
      done
    }
    run_parallel_fn _lb_to_mongo "${lb[@]}"
  fi
}
