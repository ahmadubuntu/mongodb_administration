#!/usr/bin/env bash
# Query latency on the MongoDB primary.
# Scope: whole cluster, one database (--db), or one collection (--db + --collection).
#
# Uses serverStatus, currentOp, and the top command (lifetime averages since mongod start).
# Does not walk every collection with $collStats (that is slow and pollutes latency stats).
#
# Auth: MONGO_URI / MONGO_USER, else ~/.mongorc.js / ~/.mongoshrc.js
#
#   ./check_mongo_query.sh -c config/clusters/stgmongo.env -y
#   ./check_mongo_query.sh -c config/clusters/stgmongo.env -y --db ai_karkas_db
#   ./check_mongo_query.sh -c config/clusters/stgmongo.env -y --db ai_karkas_db --collection content_studio_contents
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="$(cat "${ROOT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]' || echo 0.0.0)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/mongo_cluster.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/report.sh"

CONFIG_FILE=""
NONINTERACTIVE=0
REPORT_FILE_OVERRIDE=""
QUERY_DB=""
QUERY_COLL=""

usage() {
  cat <<EOF
Usage: $(basename "$0") -c CONFIG.env [options]

MongoDB query latency v${SCRIPT_VERSION}

Scope:
  (default)                 whole cluster — global latency, queue, slowest namespaces
  --db NAME                 one database
  --db NAME --collection C  one collection (server explain of find().limit(1) included)

Options:
  -c, --config FILE     Cluster inventory (.env)
  --db NAME             Database to inspect
  --collection NAME     Collection inside --db
  --min-ops N           Ignore FAIL under this sample count (default TOP_MIN_OPS or 20)
  --warn-ms N           Average ms WARN threshold (default TOP_QUERY_WARN_MS or 50)
  --fail-ms N           Average ms FAIL threshold (default TOP_QUERY_FAIL_MS or 200)
  -o, --report FILE     Report path
  -y, --yes             Non-interactive
  -h, --help

Exit codes: 0=PASS, 1=WARN, 2=FAIL
Auth comes from MONGO_URI or ~/.mongorc.js. Passwords are not logged.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config) CONFIG_FILE="$2"; shift 2 ;;
      --db) QUERY_DB="$2"; shift 2 ;;
      --collection|--coll) QUERY_COLL="$2"; shift 2 ;;
      --min-ops) TOP_MIN_OPS="$2"; shift 2 ;;
      --warn-ms) TOP_QUERY_WARN_MS="$2"; shift 2 ;;
      --fail-ms) TOP_QUERY_FAIL_MS="$2"; shift 2 ;;
      -o|--report) REPORT_FILE_OVERRIDE="$2"; shift 2 ;;
      -y|--yes) NONINTERACTIVE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) loge "Unknown argument: $1"; usage; exit 2 ;;
    esac
  done
}

load_config() {
  if [[ -z "$CONFIG_FILE" ]]; then
    loge "Missing -c/--config"; usage; exit 2
  fi
  if [[ ! -f "$CONFIG_FILE" && -f "${ROOT_DIR}/${CONFIG_FILE}" ]]; then
    CONFIG_FILE="${ROOT_DIR}/${CONFIG_FILE}"
  fi
  [[ -f "$CONFIG_FILE" ]] || { loge "Config not found: $CONFIG_FILE"; exit 2; }
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
}

_mongo_uri_for_hostport() {
  local target="$1"
  local host="${target%%:*}" port="${target##*:}"
  local user="${MONGO_USER:-}" pass="${MONGO_PASSWORD:-}" authdb="${MONGO_AUTH_DB:-admin}"
  if [[ -n "${MONGO_URI:-}" && -z "${user}" ]]; then
    # Inventory URI may point at a secondary; still prefer it only when no parsed user.
    echo "$MONGO_URI"
    return
  fi
  local auth="" q="authSource=${authdb}&directConnection=true"
  if [[ -n "$user" ]]; then
    auth="$(_mongo_uri_escape "$user"):$(_mongo_uri_escape "$pass")@"
  fi
  echo "mongodb://${auth}${host}:${port}/admin?${q}"
}

_mongosh_eval() {
  local uri="$1" js="$2"
  timeout "${MONGO_ADMIN_TIMEOUT_SEC:-60}" mongosh --quiet "$uri" --eval "$js" </dev/null 2>&1
}

discover_primary() {
  local first
  first="$(echo "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}" | cut -d, -f1 | tr -d ' ')"
  [[ -n "$first" ]] || { loge "MONGOD_HOSTS empty"; return 2; }
  [[ "$first" == *:* ]] || first="${first}:${MONGO_PORT:-27017}"
  local uri out
  uri="$(_mongo_uri_for_hostport "$first")"
  out="$(_mongosh_eval "$uri" 'var h=db.hello(); print("PRIMARY="+(h.primary||h.me||"")); print("ME="+(h.me||""));')" || true
  if echo "$out" | grep -qi 'requires authentication\|Unauthorized\|Authentication failed'; then
    record_check "query" "auth" "WARN" "auth failed — check ~/.mongorc.js or MONGO_URI"
    echo "$out" >&2
    return 13
  fi
  PRIMARY_TARGET="$(echo "$out" | awk -F= '/^PRIMARY=/{print $2}' | tail -1)"
  [[ -n "$PRIMARY_TARGET" ]] || { record_check "query" "primary" "FAIL" "could not read hello().primary"; return 2; }
  record_check "query" "primary" "INFO" "PRIMARY=${PRIMARY_TARGET}"
}

run_query_probe() {
  local uri js out rc=0
  uri="$(_mongo_uri_for_hostport "$PRIMARY_TARGET")"
  export LATENCY_SCOPE LATENCY_DB LATENCY_COLL
  export TOP_MIN_OPS="${TOP_MIN_OPS:-20}"
  export TOP_QUERY_WARN_MS="${TOP_QUERY_WARN_MS:-50}"
  export TOP_QUERY_FAIL_MS="${TOP_QUERY_FAIL_MS:-200}"
  export TOP_LIST_LIMIT="${TOP_LIST_LIMIT:-12}"
  export EXPLAIN_WARN_MS="${EXPLAIN_WARN_MS:-50}"
  export EXPLAIN_FAIL_MS="${EXPLAIN_FAIL_MS:-500}"
  export LIVE_SLOW_SEC="${LIVE_SLOW_SEC:-1}"

  js=$(cat <<'JS'
function avgMs(b) {
  if (!b || !b.count) return 0;
  return b.time / b.count / 1000;
}
function emit(status, cat, name, msg) {
  msg = String(msg == null ? "" : msg).replace(/\|/g, "/").replace(/[\r\n]+/g, " ");
  print(["CHECK", status, cat, name, msg].join("|"));
}
function sev(avg, n) {
  var minOps = Number(process.env.TOP_MIN_OPS || 20);
  var warn = Number(process.env.TOP_QUERY_WARN_MS || 50);
  var fail = Number(process.env.TOP_QUERY_FAIL_MS || 200);
  if (!n) return "INFO";
  var st = "PASS";
  if (avg >= fail) st = "FAIL";
  else if (avg >= warn) st = "WARN";
  if (n < minOps && st === "FAIL") st = "WARN";
  return st;
}
function skipNs(ns) {
  if (!ns) return true;
  if (ns.indexOf("admin.") === 0 || ns.indexOf("local.") === 0 || ns.indexOf("config.") === 0) return true;
  if (ns.indexOf(".system.") >= 0) return true;
  return false;
}
var scope = process.env.LATENCY_SCOPE || "cluster";
var dbName = process.env.LATENCY_DB || "";
var collName = process.env.LATENCY_COLL || "";
var minOps = Number(process.env.TOP_MIN_OPS || 20);
var listLimit = Number(process.env.TOP_LIST_LIMIT || 12);
var liveSec = Number(process.env.LIVE_SLOW_SEC || 1);
var explainWarn = Number(process.env.EXPLAIN_WARN_MS || 50);
var explainFail = Number(process.env.EXPLAIN_FAIL_MS || 500);

var hello = db.hello();
var ss = db.serverStatus();
var gl = ss.globalLock || {};
var q = gl.currentQueue || {};
var op = ss.opLatencies || {};
emit("INFO", "query", "uptime", "uptime_h=" + (ss.uptime / 3600).toFixed(1) + " conn=" + ss.connections.current + " primary=" + (hello.primary || hello.me));
function gsev(avg) {
  var warn = Number(process.env.TOP_QUERY_WARN_MS || 50);
  var fail = Number(process.env.TOP_QUERY_FAIL_MS || 200);
  if (avg >= fail) return "FAIL";
  if (avg >= warn) return "WARN";
  return "PASS";
}
var rAvg = (op.reads && op.reads.ops) ? (op.reads.latency / op.reads.ops / 1000) : 0;
var wAvg = (op.writes && op.writes.ops) ? (op.writes.latency / op.writes.ops / 1000) : 0;
var cAvg = (op.commands && op.commands.ops) ? (op.commands.latency / op.commands.ops / 1000) : 0;
emit(gsev(rAvg), "query", "global-read", "avg_ms=" + rAvg.toFixed(2) + " ops=" + ((op.reads && op.reads.ops) || 0));
emit(gsev(wAvg), "query", "global-write", "avg_ms=" + wAvg.toFixed(2) + " ops=" + ((op.writes && op.writes.ops) || 0));
emit("INFO", "query", "global-cmd", "avg_ms=" + cAvg.toFixed(2) + " ops=" + ((op.commands && op.commands.ops) || 0));
var qr = q.readers || 0, qw = q.writers || 0;
emit((qw > 0 || qr > 0) ? "WARN" : "PASS", "query", "queue", "readers=" + qr + " writers=" + qw);

var wt = ss.wiredTiger && ss.wiredTiger.cache;
if (wt) {
  var max = wt["maximum bytes configured"] || 0;
  var dirty = wt["tracked dirty bytes in the cache"] || 0;
  var used = wt["bytes currently in the cache"] || 0;
  var dirtyPct = max ? (100 * dirty / max) : 0;
  var usedPct = max ? (100 * used / max) : 0;
  emit(dirtyPct >= 50 ? "WARN" : "PASS", "query", "wt-cache", "used_pct=" + usedPct.toFixed(1) + " dirty_pct=" + dirtyPct.toFixed(1));
}

function wantNs(ns) {
  if (skipNs(ns)) return false;
  if (scope === "cluster") return true;
  if (scope === "db") return ns.indexOf(dbName + ".") === 0;
  return ns === (dbName + "." + collName);
}

var top = db.adminCommand({ top: 1 });
var rows = [];
var small = [];
Object.keys(top.totals || {}).forEach(function (ns) {
  if (!wantNs(ns)) return;
  var t = top.totals[ns];
  ["queries", "getmore", "insert", "update", "remove", "commands"].forEach(function (kind) {
    var b = t[kind] || {};
    var n = b.count || 0;
    if (!n) return;
    rows.push({ ns: ns, kind: kind, n: n, avg: avgMs(b) });
  });
});
rows.sort(function (a, b) { return b.avg - a.avg; });
var flagged = 0;
var shown = 0;
rows.forEach(function (row) {
  if (row.n < minOps) {
    if (row.avg >= Number(process.env.TOP_QUERY_WARN_MS || 50)) small.push(row);
    return;
  }
  var st = sev(row.avg, row.n);
  if (st === "WARN" || st === "FAIL") {
    flagged++;
    emit(st, "query", row.kind + ":" + row.ns, "avg_ms=" + row.avg.toFixed(2) + " n=" + row.n);
    return;
  }
  if (shown < listLimit && (row.kind === "queries" || row.kind === "commands" || row.kind === "update")) {
    shown++;
    emit("PASS", "query", row.kind + ":" + row.ns, "avg_ms=" + row.avg.toFixed(2) + " n=" + row.n);
  }
});
small.sort(function (a, b) { return b.avg - a.avg; });
small.slice(0, 5).forEach(function (row) {
  emit("INFO", "query", "small-sample:" + row.kind + ":" + row.ns, "avg_ms=" + row.avg.toFixed(2) + " n=" + row.n + " below_min_ops=" + minOps);
});
if (flagged === 0) {
  emit("PASS", "query", "slow-namespaces", "no namespace with n>=" + minOps + " at or above the warn threshold");
} else {
  emit("INFO", "query", "slow-namespaces", "flagged=" + flagged);
}

var cops = db.aggregate([{ $currentOp: { allUsers: true, idleConnections: false } }]).toArray();
var live = 0;
cops.forEach(function (opx) {
  var ns = opx.ns || "";
  var sec = opx.secs_running || 0;
  if (sec < liveSec) return;
  if (!ns || ns === "admin.$cmd") return;
  if (scope === "db" && ns.indexOf(dbName + ".") !== 0 && ns !== dbName) return;
  if (scope === "collection" && ns !== (dbName + "." + collName)) return;
  live++;
  if (live <= 8) {
    emit(sec >= 5 ? "FAIL" : "WARN", "query", "live:" + ns, sec + "s op=" + (opx.op || "") + " plan=" + (opx.planSummary || ""));
  }
});
emit(live ? "INFO" : "PASS", "query", "live-slow", "count=" + live + " threshold_s=" + liveSec);

if (scope === "db" || scope === "collection") {
  var kdb = db.getSiblingDB(dbName);
  var st = kdb.stats();
  emit("INFO", "query", "db-stats", "data_mb=" + ((st.dataSize || 0) / 1048576).toFixed(1) + " colls=" + (st.collections || 0) + " objects=" + (st.objects || 0) + " indexes=" + (st.indexes || 0));
  var prof = kdb.getProfilingStatus();
  emit("INFO", "query", "profiler", "level=" + prof.was + " slowms=" + prof.slowms);
}
if (scope === "collection") {
  var kdb2 = db.getSiblingDB(dbName);
  var cs;
  try { cs = kdb2.getCollection(collName).stats(); }
  catch (e) { emit("FAIL", "query", "coll-stats", String(e)); cs = null; }
  if (cs) {
    emit("INFO", "query", "coll-stats", "docs=" + cs.count + " size_mb=" + ((cs.size || 0) / 1048576).toFixed(1) + " indexes=" + cs.nindexes + " totalIndex_mb=" + ((cs.totalIndexSize || 0) / 1048576).toFixed(1));
  }
  var exp = kdb2.getCollection(collName).find({}).limit(1).explain("executionStats");
  var ms = (exp.executionStats && exp.executionStats.executionTimeMillis) || 0;
  var est = "PASS";
  if (ms >= explainFail) est = "FAIL";
  else if (ms >= explainWarn) est = "WARN";
  emit(est, "query", "explain-find1", "server_ms=" + ms + " docsExamined=" + ((exp.executionStats && exp.executionStats.totalDocsExamined) || 0) + " keysExamined=" + ((exp.executionStats && exp.executionStats.totalKeysExamined) || 0));
}
JS
)
  out="$(_mongosh_eval "$uri" "$js")" || rc=$?
  if echo "$out" | grep -qi 'requires authentication\|Unauthorized\|Authentication failed'; then
    record_check "query" "auth" "WARN" "auth failed on primary — check ~/.mongorc.js or MONGO_URI"
    return 0
  fi
  if [[ $rc -ne 0 ]] && ! printf '%s\n' "$out" | grep -q '^CHECK|'; then
    record_check "query" "mongosh" "FAIL" "probe failed rc=${rc}"
    printf '%s\n' "$out" | tail -20 >&2
    return 0
  fi
  local line status cat name msg
  while IFS= read -r line; do
    [[ "$line" == CHECK\|* ]] || continue
    IFS='|' read -r _ status cat name msg <<<"$line"
    record_check "$cat" "$name" "$status" "$msg"
  done <<<"$out"
}

main() {
  parse_args "$@"
  if [[ -n "$QUERY_COLL" && -z "$QUERY_DB" ]]; then
    loge "--collection requires --db"; exit 2
  fi
  load_config
  # CLI thresholds win over inventory sourced above
  have_cmd mongosh || { loge "mongosh not found on this machine"; exit 2; }

  if [[ -n "$QUERY_COLL" ]]; then
    LATENCY_SCOPE="collection"
  elif [[ -n "$QUERY_DB" ]]; then
    LATENCY_SCOPE="db"
  else
    LATENCY_SCOPE="cluster"
  fi
  LATENCY_DB="$QUERY_DB"
  LATENCY_COLL="$QUERY_COLL"

  init_result_store
  install_interrupt_traps
  init_report_file "${REPORT_FILE_OVERRIDE}"

  emit "${C_BOLD}MongoDB query latency v${SCRIPT_VERSION}${C_RESET} — ${CLUSTER_NAME:-cluster}"
  emit "Scope: ${LATENCY_SCOPE}${QUERY_DB:+ db=${QUERY_DB}}${QUERY_COLL:+ collection=${QUERY_COLL}}"
  emit "Config: ${CONFIG_FILE}"
  mongo_resolve_credentials

  section "Query latency (${LATENCY_SCOPE})"
  set +e
  discover_primary || { set -e; print_summary; exit $?; }
  run_query_probe
  set -e

  local rc=0
  print_summary || rc=$?
  exit "$rc"
}

main "$@"
