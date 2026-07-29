#!/usr/bin/env bash
# MongoDB stack core: services, RS membership/primary/lag, sharded balancer, disk, config drift.
# shellcheck shell=bash

_mongo_bin_local() {
  if have_cmd mongosh; then echo mongosh; return 0; fi
  if have_cmd mongo; then echo mongo; return 0; fi
  return 1
}

_mongo_build_uri() {
  if [[ -n "${MONGO_URI:-}" ]]; then
    echo "$MONGO_URI"
    return
  fi
  local target="${MONGO_CONNECT_TARGET:-}"
  if [[ -z "$target" ]]; then
    local h
    h="$(echo "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}" | cut -d, -f1 | tr -d ' ')"
    [[ -n "$h" ]] && target="${h}:${MONGO_PORT:-27017}"
  fi
  [[ -n "$target" ]] || { echo ""; return 1; }
  local host="${target%%:*}" port="${target##*:}"
  local user="${MONGO_USER:-}" pass="${MONGO_PASSWORD:-}" authdb="${MONGO_AUTH_DB:-admin}"
  local opts="${MONGO_URI_OPTS:-}" rs="${REPLICA_SET_NAME:-}"
  local auth="" q="directConnection=true"
  if [[ -n "$user" ]]; then
    auth="${user}"
    [[ -n "$pass" ]] && auth+=":${pass}"
    auth+="@"
    q="authSource=${authdb}"
    [[ -n "$rs" ]] && q+="&replicaSet=${rs}"
  elif [[ -n "$rs" ]]; then
    q="replicaSet=${rs}&directConnection=true"
  fi
  [[ -n "$opts" ]] && q="${q}&${opts}"
  echo "mongodb://${auth}${host}:${port}/?${q}"
}

_mongo_eval_local() {
  local js="$1"
  local bin uri out rc=0
  bin="$(_mongo_bin_local)" || { echo "MISSING_TOOL"; return 127; }
  uri="$(_mongo_build_uri)" || { echo "NO_URI"; return 2; }
  out="$(timeout "${MONGO_ADMIN_TIMEOUT_SEC:-30}" "$bin" --quiet "$uri" --eval "$js" </dev/null 2>&1)" || rc=$?
  if echo "$out" | grep -qi 'requires authentication\|Unauthorized\|Authentication failed'; then
    echo "Unauthorized: requires authentication"
    return 13
  fi
  echo "$out"
  return "$rc"
}

_mongo_eval_on_host() {
  # Run mongosh/mongo on a cluster node via SSH (uses node-local URI or localhost).
  local host="$1" js="$2"
  local uri="${MONGO_URI:-}"
  local port="${MONGO_PORT:-27017}"
  local user="${MONGO_USER:-}" pass="${MONGO_PASSWORD:-}" authdb="${MONGO_AUTH_DB:-admin}"
  local bin_hint="${MONGO_BIN:-}"
  local uri_q js_q
  js_q="$(printf '%q' "$js")"
  if [[ -n "$uri" ]]; then
    uri_q="$(printf '%q' "$uri")"
  else
    local auth="" q="directConnection=true"
    if [[ -n "$user" ]]; then
      auth="${user}"
      [[ -n "$pass" ]] && auth+=":${pass}"
      auth+="@"
      q="authSource=${authdb}"
    fi
    uri_q="$(printf '%q' "mongodb://${auth}127.0.0.1:${port}/?${q}")"
  fi
  local remote_cmd
  remote_cmd="JS=${js_q}; URI=${uri_q}; BIN=''; "
  remote_cmd+="for c in ${bin_hint:+${bin_hint}/mongosh ${bin_hint}/mongo }mongosh mongo; do "
  remote_cmd+="if command -v \"\$c\" >/dev/null 2>&1; then BIN=\$(command -v \"\$c\"); break; fi; "
  remote_cmd+="if [[ -x \"\$c\" ]]; then BIN=\"\$c\"; break; fi; done; "
  remote_cmd+="[[ -n \"\$BIN\" ]] || { echo MISSING_TOOL; exit 127; }; "
  remote_cmd+="OUT=\$(timeout ${MONGO_ADMIN_TIMEOUT_SEC:-30} \"\$BIN\" --quiet \"\$URI\" --eval \"\$JS\" </dev/null 2>&1); RC=\$?; "
  remote_cmd+="if printf '%s' \"\$OUT\" | grep -qiE 'requires authentication|Unauthorized|Authentication failed'; then echo 'Unauthorized: requires authentication'; exit 13; fi; "
  remote_cmd+="printf '%s\\n' \"\$OUT\"; exit \$RC"
  remote_run "$host" 0 "bash -lc $(printf '%q' "$remote_cmd")"
}

_mongo_eval() {
  # Prefer local CLI (hello/ping work without auth); else SSH to first OK mongod.
  local js="$1"
  local out rc=0
  if _mongo_bin_local >/dev/null; then
    out="$(_mongo_eval_local "$js")" || rc=$?
    if [[ $rc -eq 0 && "$out" != MISSING_TOOL && "$out" != NO_URI ]]; then
      echo "$out"
      return 0
    fi
    if echo "$out" | grep -qiE 'Authentication|Unauthorized|MISSING_TOOL|NO_URI'; then
      :
    elif [[ $rc -eq 0 ]]; then
      echo "$out"
      return 0
    fi
  fi

  local nodes=() h
  csv_to_array nodes "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}"
  if [[ "${MONGO_MODE:-replicaset}" == "sharded" && -n "${MONGOS_HOSTS:-}" ]]; then
    local routers=()
    csv_to_array routers "${MONGOS_HOSTS}"
    nodes=("${routers[@]}" "${nodes[@]}")
  fi
  for h in "${nodes[@]}"; do
    ssh_host_is_ok "$h" || continue
    out="$(_mongo_eval_on_host "$h" "$js")" || rc=$?
    echo "$out"
    return "$rc"
  done
  echo "NO_LOCAL_BIN_AND_NO_SSH"
  return 127
}

_mongo_hello_dump() {
  _mongo_eval '
var h=db.hello();
print("ok="+(h.ok||0));
print("set="+(h.setName||""));
print("me="+(h.me||""));
print("primary="+(h.primary||""));
print("isPrimary="+(h.isWritablePrimary||h.ismaster||false));
print("secondary="+(h.secondary||false));
(h.hosts||[]).forEach(function(x){ print("host|"+x); });
(h.passives||[]).forEach(function(x){ print("passive|"+x); });
(h.arbiters||[]).forEach(function(x){ print("arbiter|"+x); });
'
}

_mongo_auth_warn_if_needed() {
  local out="$1" check="$2"
  if echo "$out" | grep -qiE 'Authentication failed|Unauthorized|requires authentication'; then
    record_check "$check" "auth" "WARN" \
      "auth failed — set MONGO_URI or MONGO_USER/MONGO_PASSWORD (authSource=${MONGO_AUTH_DB:-admin}); not a cluster FAIL"
    return 0
  fi
  if echo "$out" | grep -q 'MISSING_TOOL\|NO_LOCAL_BIN_AND_NO_SSH\|NO_URI'; then
    record_check "$check" "tooling" "WARN" \
      "mongosh/mongo unavailable on checker and no SSH path — install mongosh or fix SSH; TCP-only checks still ran"
    return 0
  fi
  return 1
}

check_mongo_services() {
  section "MongoDB systemd units"
  local h seen="|" unit_m="${MONGOD_SYSTEMD_UNIT:-mongod}" unit_s="${MONGOS_SYSTEMD_UNIT:-mongos}"
  local role_hosts arr role unit

  _svc_role() {
    role="$1"; unit="$2"; role_hosts="$3"
    arr=()
    csv_to_array arr "$role_hosts"
    for h in "${arr[@]}"; do
      [[ -z "$h" || "$seen" == *"|${h}|${unit}|"* ]] && continue
      seen+="${h}|${unit}|"
      if ! ssh_host_is_ok "$h"; then
        record_check "service" "${role}:${h}" "SKIP" "SSH unavailable"
        continue
      fi
      check_systemd_active "$h" "$unit" "$role"
    done
  }

  _svc_role "mongod" "$unit_m" "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}"
  _svc_role "mongos" "$unit_s" "${MONGOS_HOSTS:-}"
  # Config servers often share mongod unit name
  _svc_role "configsvr" "${CONFIGSVR_SYSTEMD_UNIT:-$unit_m}" "${CONFIGSVR_HOSTS:-}"
}

check_mongo_membership() {
  section "Replica set membership vs inventory"
  local mode="${MONGO_MODE:-replicaset}"
  if [[ "$mode" == "standalone" ]]; then
    record_check "membership" "mode" "INFO" "MONGO_MODE=standalone — skip RS membership"
    return
  fi

  # hello works without auth; rs.status needs credentials for health details
  local out rc=0
  out="$(_mongo_hello_dump)" || rc=$?
  if _mongo_auth_warn_if_needed "$out" "membership"; then
    return
  fi
  if [[ $rc -ne 0 ]] || ! echo "$out" | grep -q '^ok=1'; then
    record_check "membership" "hello" "FAIL" "cannot read db.hello() (rc=${rc})" "$out"
    return
  fi

  local set_name
  set_name="$(echo "$out" | awk -F= '/^set=/{print $2}')"
  if [[ -n "${REPLICA_SET_NAME:-}" && -n "$set_name" && "$set_name" != "$REPLICA_SET_NAME" ]]; then
    record_check "membership" "set-name" "FAIL" "live set=${set_name} != REPLICA_SET_NAME=${REPLICA_SET_NAME}"
  else
    record_check "membership" "set-name" "PASS" "replica set=${set_name:-unknown}"
  fi

  local live_hosts=() line
  while IFS= read -r line; do
    [[ "$line" == host\|* || "$line" == passive\|* || "$line" == arbiter\|* ]] || continue
    live_hosts+=("${line#*|}")
  done <<<"$out"
  local live_n=${#live_hosts[@]}

  local inv=()
  csv_to_array inv "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}"
  local inv_n=${#inv[@]}
  local expect_n="${EXPECT_MEMBERS:-$inv_n}"
  record_check "membership" "inventory-count" "INFO" "inventory mongod=${inv_n} EXPECT_MEMBERS=${expect_n}"

  if [[ "$live_n" -eq "$expect_n" ]]; then
    record_check "membership" "member-count" "PASS" "live=${live_n} matches expected=${expect_n}"
  elif [[ "$live_n" -lt "$expect_n" ]]; then
    record_check "membership" "member-count" "FAIL" "live=${live_n} < expected=${expect_n} — missing members"
  else
    record_check "membership" "member-count" "WARN" "live=${live_n} > expected=${expect_n} — inventory incomplete? set EXPECT_MEMBERS"
  fi

  # Compare inventory hostnames/IPs against hello hosts (strip :port)
  local inv_h live_h found h lh
  for h in "${inv[@]}"; do
    found=0
    inv_h="${h%%:*}"
    for lh in "${live_hosts[@]}"; do
      live_h="${lh%%:*}"
      if [[ "$live_h" == "$inv_h" || "$lh" == "$h" || "$lh" == "${h}:${MONGO_PORT:-27017}" ]]; then
        found=1
        record_check "membership" "member:${lh}" "PASS" "present in hello.hosts"
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      record_check "membership" "member:${h}" "FAIL" "inventory host missing from hello.hosts"
    fi
  done

  # Richer health via rs.status when auth available (suppress mongosh /dev/tty noise)
  local rs_out rs_rc=0
  rs_out="$(_mongo_eval '
var s=rs.status();
print("ok="+s.ok);
(s.members||[]).forEach(function(m){
  print(["m", m.name, m.stateStr, m.health].join("|"));
});
' 2>/dev/null)" || rs_rc=$?
  # Drop multi-line stack traces; keep first line markers
  if echo "$rs_out" | grep -qiE 'Authentication|Unauthorized|requires authentication'; then
    record_check "membership" "rs.status" "INFO" \
      "rs.status needs auth — member health from hello only; set MONGO_URI or MONGO_USER/MONGO_PASSWORD for full status"
    return
  fi
  if [[ $rs_rc -eq 0 ]] && echo "$rs_out" | grep -q '^ok=1'; then
    local name state health
    while IFS= read -r line; do
      [[ "$line" == m\|* ]] || continue
      name="$(echo "$line" | cut -d'|' -f2)"
      state="$(echo "$line" | cut -d'|' -f3)"
      health="$(echo "$line" | cut -d'|' -f4)"
      if [[ "$health" != "1" ]] || [[ "$state" == *"(not reachable/healthy)"* ]]; then
        record_check "membership" "health:${name}" "FAIL" "state=${state} health=${health}"
      else
        record_check "membership" "health:${name}" "PASS" "state=${state}"
      fi
    done <<<"$rs_out"
  fi
}

check_mongo_primary() {
  section "Primary / election"
  local mode="${MONGO_MODE:-replicaset}"
  if [[ "$mode" == "standalone" ]]; then
    record_check "primary" "mode" "INFO" "standalone — skip PRIMARY check"
    return
  fi

  local out rc=0
  out="$(_mongo_hello_dump)" || rc=$?
  if _mongo_auth_warn_if_needed "$out" "primary"; then
    return
  fi
  if [[ $rc -ne 0 ]] || ! echo "$out" | grep -q '^ok=1'; then
    record_check "primary" "hello" "FAIL" "cannot determine PRIMARY (rc=${rc})" "$out"
    return
  fi

  local primary
  primary="$(echo "$out" | awk -F= '/^primary=/{print $2}')"
  if [[ -n "$primary" ]]; then
    record_check "primary" "count" "PASS" "exactly one PRIMARY (${primary})"
    MONGO_PRIMARY_HOST="${primary%%:*}"
    MONGO_PRIMARY_TARGET="$primary"
    export MONGO_PRIMARY_HOST MONGO_PRIMARY_TARGET
  else
    record_check "primary" "count" "FAIL" "no PRIMARY in hello — election in progress or RS down"
  fi

  # Optional electionDate from rs.status when auth works
  local rs_out
  rs_out="$(_mongo_eval 'var s=rs.status(); if(s.electionDate) print("electionDate="+s.electionDate.toISOString());' 2>/dev/null)" || true
  if echo "$rs_out" | grep -q '^electionDate='; then
    local ed now_epoch ed_epoch age_sec
    ed="$(echo "$rs_out" | awk -F= '/^electionDate=/{print $2}')"
    now_epoch="$(date +%s)"
    ed_epoch="$(date -d "$ed" +%s 2>/dev/null || echo 0)"
    if [[ "$ed_epoch" -gt 0 ]]; then
      age_sec=$(( now_epoch - ed_epoch ))
      if (( age_sec < ${ELECTION_RECENT_WARN_SEC:-3600} )); then
        record_check "primary" "election" "WARN" "recent election ${age_sec}s ago (${ed})"
      else
        record_check "primary" "election" "INFO" "last electionDate=${ed} (${age_sec}s ago)"
      fi
    fi
  fi
}

check_mongo_lag() {
  section "Replication lag"
  local mode="${MONGO_MODE:-replicaset}"
  if [[ "$mode" == "standalone" ]]; then
    record_check "lag" "mode" "INFO" "standalone — skip lag"
    return
  fi

  local out rc=0
  out="$(_mongo_eval '
var s=rs.status();
var primary=null;
(s.members||[]).forEach(function(m){ if(m.stateStr==="PRIMARY") primary=m; });
if(!primary || !primary.optimeDate){ print("NO_PRIMARY_OPTIME"); quit(0); }
var pms=primary.optimeDate.getTime();
(s.members||[]).forEach(function(m){
  if(m.stateStr!=="SECONDARY" && m.stateStr!=="HIDDEN") return;
  if(!m.optimeDate){ print(["lag", m.name, m.stateStr, "NA"].join("|")); return; }
  var lagMs=pms - m.optimeDate.getTime();
  if(lagMs<0) lagMs=0;
  print(["lag", m.name, m.stateStr, Math.round(lagMs/1000)].join("|"));
});
')" || rc=$?

  if _mongo_auth_warn_if_needed "$out" "lag"; then
    return
  fi
  if echo "$out" | grep -q 'NO_PRIMARY_OPTIME'; then
    record_check "lag" "primary" "SKIP" "no PRIMARY optimeDate"
    return
  fi
  if [[ $rc -ne 0 ]]; then
    record_check "lag" "rs.status" "FAIL" "cannot compute lag (rc=${rc})" "$out"
    return
  fi

  local line name state lag_s warn_s fail_s
  warn_s="${LAG_WARN_SEC:-10}"
  fail_s="${LAG_FAIL_SEC:-60}"
  local any=0
  while IFS= read -r line; do
    [[ "$line" == lag\|* ]] || continue
    any=1
    name="$(echo "$line" | cut -d'|' -f2)"
    state="$(echo "$line" | cut -d'|' -f3)"
    lag_s="$(echo "$line" | cut -d'|' -f4)"
    if [[ "$lag_s" == "NA" ]]; then
      record_check "lag" "${name}" "WARN" "no optimeDate (state=${state})"
      continue
    fi
    if (( lag_s >= fail_s )); then
      record_check "lag" "${name}" "FAIL" "lag=${lag_s}s ≥ ${fail_s}s (state=${state})"
    elif (( lag_s >= warn_s )); then
      record_check "lag" "${name}" "WARN" "lag=${lag_s}s ≥ ${warn_s}s (state=${state})"
    else
      record_check "lag" "${name}" "PASS" "lag=${lag_s}s (state=${state})"
    fi
  done <<<"$out"
  if [[ $any -eq 0 ]]; then
    record_check "lag" "secondaries" "INFO" "no SECONDARY/HIDDEN members to measure"
  fi
}

check_mongo_disk_dbpath() {
  section "dbPath disk"
  local hosts=() h path="${MONGO_DBPATH:-/var/lib/mongodb}"
  csv_to_array hosts "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}"
  for h in "${hosts[@]}"; do
    if ! ssh_host_is_ok "$h"; then
      record_check "disk" "dbpath:${h}" "SKIP" "SSH unavailable"
      continue
    fi
    local out pct
    out="$(remote_run "$h" 0 "df -P ${path} 2>/dev/null | awk 'NR==2{print \$5\" \"\$6}'" 2>&1)" || true
    pct="$(echo "$out" | awk '{gsub(/%/,"",$1); print $1}')"
    if [[ ! "$pct" =~ ^[0-9]+$ ]]; then
      record_check "disk" "dbpath:${h}" "SKIP" "cannot df ${path}" "$out"
      continue
    fi
    local msg="${path} ${pct}% used on ${h}"
    if (( pct >= ${DISK_FAIL_PCT:-90} )); then
      record_check "disk" "dbpath:${h}" "FAIL" "$msg"
    elif (( pct >= ${DISK_WARN_PCT:-80} )); then
      record_check "disk" "dbpath:${h}" "WARN" "$msg"
    else
      record_check "disk" "dbpath:${h}" "PASS" "$msg"
    fi
  done
}

check_mongo_oplog() {
  section "Oplog window"
  local mode="${MONGO_MODE:-replicaset}"
  [[ "$mode" == "standalone" ]] && { record_check "oplog" "mode" "INFO" "standalone — skip"; return; }

  local out rc=0
  out="$(_mongo_eval '
try {
  var ol=db.getSiblingDB("local").oplog.rs;
  var first=ol.find().sort({$natural:1}).limit(1).next();
  var last=ol.find().sort({$natural:-1}).limit(1).next();
  var hours=(last.ts.getTime()-first.ts.getTime())/1000/3600;
  print("hours="+hours.toFixed(2));
} catch(e) { print("ERR="+e); }
')" || rc=$?

  if _mongo_auth_warn_if_needed "$out" "oplog"; then
    return
  fi
  if echo "$out" | grep -q '^ERR='; then
    record_check "oplog" "window" "WARN" "cannot read local.oplog.rs" "$out"
    return
  fi
  local hours
  hours="$(echo "$out" | awk -F= '/^hours=/{print $2}')"
  if [[ -z "$hours" ]]; then
    record_check "oplog" "window" "SKIP" "oplog window unavailable" "$out"
    return
  fi
  local warn_h="${OPLOG_WARN_HOURS:-24}" fail_h="${OPLOG_FAIL_HOURS:-6}"
  if awk -v h="$hours" -v f="$fail_h" 'BEGIN{exit !(h+0 < f+0)}'; then
    record_check "oplog" "window" "FAIL" "oplog window≈${hours}h < ${fail_h}h — resize replication.oplogSizeMB"
  elif awk -v h="$hours" -v w="$warn_h" 'BEGIN{exit !(h+0 < w+0)}'; then
    record_check "oplog" "window" "WARN" "oplog window≈${hours}h < ${warn_h}h"
  else
    record_check "oplog" "window" "PASS" "oplog window≈${hours}h"
  fi
}

check_mongo_sharded() {
  section "Sharded cluster (balancer / shards)"
  if [[ "${MONGO_MODE:-replicaset}" != "sharded" ]]; then
    record_check "shard" "mode" "INFO" "MONGO_MODE=${MONGO_MODE:-replicaset} — skip sharded checks"
    return
  fi

  local out rc=0
  out="$(_mongo_eval '
var bal=sh.getBalancerState();
print("balancer="+bal);
var shards=db.getSiblingDB("config").shards.find().toArray();
print("shard_count="+shards.length);
shards.forEach(function(s){ print("shard|"+s._id+"|"+s.host); });
')" || rc=$?

  if _mongo_auth_warn_if_needed "$out" "shard"; then
    return
  fi
  if [[ $rc -ne 0 ]]; then
    record_check "shard" "status" "FAIL" "cannot query balancer/shards (rc=${rc})" "$out"
    return
  fi

  local bal expect_b="${EXPECT_BALANCER:-}"
  bal="$(echo "$out" | awk -F= '/^balancer=/{print $2}')"
  if [[ -n "$expect_b" ]]; then
    local want="false"
    [[ "$expect_b" == "1" || "$expect_b" == "true" ]] && want="true"
    if [[ "$bal" == "$want" ]]; then
      record_check "shard" "balancer" "PASS" "balancer=${bal} matches EXPECT_BALANCER=${expect_b}"
    else
      record_check "shard" "balancer" "WARN" "balancer=${bal} != EXPECT_BALANCER=${expect_b}"
    fi
  else
    record_check "shard" "balancer" "INFO" "balancer=${bal} (set EXPECT_BALANCER=0|1 to enforce)"
  fi

  local sc inv_shards=()
  sc="$(echo "$out" | awk -F= '/^shard_count=/{print $2}')"
  csv_to_array inv_shards "${SHARD_NAMES:-}"
  if [[ ${#inv_shards[@]} -gt 0 && "$sc" =~ ^[0-9]+$ ]]; then
    if [[ "$sc" -eq ${#inv_shards[@]} ]]; then
      record_check "shard" "count" "PASS" "shards=${sc} matches SHARD_NAMES"
    else
      record_check "shard" "count" "FAIL" "shards=${sc} != inventory SHARD_NAMES (${#inv_shards[@]})"
    fi
  else
    record_check "shard" "count" "INFO" "shard_count=${sc:-?} (set SHARD_NAMES to enforce)"
  fi
}

check_mongo_config_drift() {
  section "Config drift (EXPECT_*)"
  local out rc=0
  out="$(_mongo_eval '
var p=db.adminCommand({getParameter:1, featureCompatibilityVersion:1});
if(p.featureCompatibilityVersion) print("fcv="+(p.featureCompatibilityVersion.version||p.featureCompatibilityVersion));
try {
  var ss=db.serverStatus();
  print("version="+ss.version);
} catch(e) {}
')" || rc=$?

  if _mongo_auth_warn_if_needed "$out" "config"; then
    return
  fi

  if [[ -n "${EXPECT_FCV:-}" ]]; then
    local fcv
    fcv="$(echo "$out" | awk -F= '/^fcv=/{print $2}')"
    if [[ "$fcv" == "$EXPECT_FCV" ]]; then
      record_check "config" "fcv" "PASS" "featureCompatibilityVersion=${fcv}"
    elif [[ -n "$fcv" ]]; then
      record_check "config" "fcv" "WARN" "fcv=${fcv} != EXPECT_FCV=${EXPECT_FCV}"
    else
      record_check "config" "fcv" "SKIP" "could not read FCV"
    fi
  else
    record_check "config" "fcv" "INFO" "set EXPECT_FCV to enforce featureCompatibilityVersion"
  fi

  if [[ -n "${EXPECT_TLS:-}" ]]; then
    record_check "config" "tls" "INFO" "EXPECT_TLS=${EXPECT_TLS} — verify net.tls in ${MONGO_CONF:-/etc/mongod.conf} manually via SSH if needed"
  fi
}

_mongo_time_ping_ms() {
  # stdout: milliseconds as integer (in-process ping after warmup); return 0 on success
  local mode="$1" # local|remote
  local target_or_host="$2"
  local bin uri out t0 t1 wall_ms rc=0
  # Warm once, then time a second ping inside the same mongosh process (avoids CLI startup noise)
  local js='db.runCommand({ping:1}); var t0=Date.now(); db.runCommand({ping:1}); print("ms="+(Date.now()-t0));'
  if [[ "$mode" == "local" ]]; then
    bin="$(_mongo_bin_local)" || { echo ""; return 127; }
    local saved="${MONGO_CONNECT_TARGET:-}"
    MONGO_CONNECT_TARGET="$target_or_host"
    uri="$(_mongo_build_uri)" || { MONGO_CONNECT_TARGET="$saved"; echo ""; return 2; }
    MONGO_CONNECT_TARGET="$saved"
    out="$(timeout "${MONGO_PROBE_TIMEOUT_SEC:-15}" "$bin" --quiet "$uri" --eval "$js" 2>&1)" || rc=$?
  else
    out="$(_mongo_eval_on_host "$target_or_host" "$js")" || rc=$?
  fi
  if echo "$out" | grep -qiE 'Authentication|Unauthorized'; then
    echo "AUTH"
    return 1
  fi
  local ms
  ms="$(echo "$out" | awk -F= '/^ms=/{print $2}' | tail -1)"
  if [[ $rc -ne 0 || ! "$ms" =~ ^[0-9]+$ ]]; then
    echo "FAIL:${out}"
    return 1
  fi
  echo "$ms"
  return 0
}

check_mongo_query_latency() {
  section "Query latency (checker vs PRIMARY) — {ping:1}"
  local warn_ms="${QUERY_WARN_MS:-100}"
  local fail_ms="${QUERY_FAIL_MS:-500}"
  local primary_target="${MONGO_PRIMARY_TARGET:-}"
  local primary_host="${MONGO_PRIMARY_HOST:-}"

  if [[ -z "$primary_target" ]]; then
    local hello
    hello="$(_mongo_hello_dump 2>/dev/null)" || true
    primary_target="$(echo "$hello" | awk -F= '/^primary=/{print $2}')"
    primary_host="${primary_target%%:*}"
  fi
  if [[ -z "$primary_target" ]]; then
    # Fall back to first inventory host
    local first
    first="$(echo "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}" | cut -d, -f1 | tr -d ' ')"
    [[ -n "$first" ]] || { record_check "latency" "target" "SKIP" "no mongod target"; return; }
    primary_host="$first"
    primary_target="${first}:${MONGO_PORT:-27017}"
    record_check "latency" "target" "INFO" "PRIMARY unknown — probing ${primary_target}"
  else
    record_check "latency" "target" "INFO" "PRIMARY=${primary_target}"
  fi

  local local_ms remote_ms

  if ! _mongo_bin_local >/dev/null; then
    record_check "latency" "from-checker" "SKIP" "mongosh/mongo not installed on checker"
  else
    local_ms="$(_mongo_time_ping_ms local "$primary_target")" || true
    if [[ "$local_ms" == "AUTH" ]]; then
      record_check "latency" "from-checker" "WARN" "auth blocked ping — set MONGO_URI or credentials"
    elif [[ "$local_ms" == FAIL:* ]]; then
      record_check "latency" "from-checker" "FAIL" "ping failed to ${primary_target}" "${local_ms#FAIL:}"
    elif [[ "$local_ms" =~ ^[0-9]+$ ]]; then
      if (( local_ms >= fail_ms )); then
        record_check "latency" "from-checker" "FAIL" "${local_ms}ms ≥ ${fail_ms}ms to ${primary_target}"
      elif (( local_ms >= warn_ms )); then
        record_check "latency" "from-checker" "WARN" "${local_ms}ms ≥ ${warn_ms}ms to ${primary_target}"
      else
        record_check "latency" "from-checker" "PASS" "${local_ms}ms to ${primary_target}"
      fi
    else
      record_check "latency" "from-checker" "FAIL" "unexpected timing result" "$local_ms"
    fi
  fi

  if [[ -z "$primary_host" ]] || ! ssh_host_is_ok "$primary_host"; then
    # Fallback: time ping to PRIMARY from any SSH-OK member (cross-host, still "from cluster")
    local alt="" nodes=() h
    csv_to_array nodes "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}"
    for h in "${nodes[@]}"; do
      ssh_host_is_ok "$h" || continue
      alt="$h"
      break
    done
    if [[ -z "$alt" ]]; then
      record_check "latency" "from-primary" "SKIP" "SSH to PRIMARY unavailable (and no other SSH-OK member)"
      return
    fi
    record_check "latency" "from-primary" "INFO" "PRIMARY SSH down — measuring ping to ${primary_target} from ${alt}"
    local js="db.getMongo().setReadPref('primary'); db.runCommand({ping:1}); var t0=Date.now(); db.runCommand({ping:1}); print('ms='+(Date.now()-t0));"
    # Force URI to primary on remote host
    local saved_uri="${MONGO_URI:-}" saved_user="${MONGO_USER:-}"
    MONGO_URI="mongodb://${primary_target}/?directConnection=true"
    MONGO_USER=""
    remote_ms="$(_mongo_eval_on_host "$alt" "$js" 2>/dev/null)" || true
    MONGO_URI="$saved_uri"
    MONGO_USER="$saved_user"
    remote_ms="$(echo "$remote_ms" | awk -F= '/^ms=/{print $2}' | tail -1)"
    if [[ "$remote_ms" =~ ^[0-9]+$ ]]; then
      local onbox_warn="${QUERY_ONBOX_WARN_MS:-20}"
      local onbox_fail="${QUERY_ONBOX_FAIL_MS:-200}"
      # This is peer RTT inside the cluster, not pure on-box — use checker thresholds
      if (( remote_ms >= ${QUERY_FAIL_MS:-500} )); then
        record_check "latency" "from-member" "FAIL" "${remote_ms}ms ${alt}→${primary_target}"
      elif (( remote_ms >= ${QUERY_WARN_MS:-100} )); then
        record_check "latency" "from-member" "WARN" "${remote_ms}ms ${alt}→${primary_target}"
      else
        record_check "latency" "from-member" "PASS" "${remote_ms}ms ${alt}→${primary_target}"
      fi
    else
      record_check "latency" "from-primary" "SKIP" "could not time ping via ${alt}"
    fi
    return
  fi
  remote_ms="$(_mongo_time_ping_ms remote "$primary_host")" || true
  if [[ "$remote_ms" == "AUTH" ]]; then
    record_check "latency" "from-primary" "WARN" "auth blocked local ping on ${primary_host}"
  elif [[ "$remote_ms" == FAIL:* ]]; then
    record_check "latency" "from-primary" "FAIL" "ping failed on PRIMARY ${primary_host}" "${remote_ms#FAIL:}"
  elif [[ "$remote_ms" =~ ^[0-9]+$ ]]; then
    local onbox_warn="${QUERY_ONBOX_WARN_MS:-20}"
    local onbox_fail="${QUERY_ONBOX_FAIL_MS:-200}"
    if (( remote_ms >= onbox_fail )); then
      record_check "latency" "from-primary" "FAIL" "${remote_ms}ms on-box ≥ ${onbox_fail}ms (${primary_host})"
    elif (( remote_ms >= onbox_warn )); then
      record_check "latency" "from-primary" "WARN" "${remote_ms}ms on-box ≥ ${onbox_warn}ms (${primary_host})"
    else
      record_check "latency" "from-primary" "PASS" "${remote_ms}ms on-box (${primary_host})"
    fi
  else
    record_check "latency" "from-primary" "FAIL" "unexpected timing result" "$remote_ms"
  fi

  if [[ "${local_ms:-}" =~ ^[0-9]+$ && "${remote_ms:-}" =~ ^[0-9]+$ ]]; then
    record_check "latency" "compare" "INFO" \
      "checker→PRIMARY=${local_ms}ms vs on-PRIMARY=${remote_ms}ms (delta=$(( local_ms - remote_ms ))ms network/client overhead)"
  fi
}
