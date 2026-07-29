#!/usr/bin/env bash
# MongoDB HA cluster health check
# Usage: ./check_mongo_ha.sh -c config/clusters/devmongo.env [options]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="$(cat "${ROOT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]' || echo 0.0.0)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/parallel.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/ssh.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/connectivity.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/ports_matrix.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/services.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/mongo_cluster.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/capacity.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/os_security.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/report.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/tasks.sh"

CONFIG_FILE=""
VERBOSE=0
JSON_OUT=0
USE_SUDO=1
NONINTERACTIVE=0
REPORT_FILE_OVERRIDE=""
SSH_USER_OVERRIDE="${SSH_USER_OVERRIDE:-}"
SUDO_PASSWORD_ENV="${SUDO_PASSWORD:-${SUDO_PASSWORD_ENV:-}}"

# id|prereqs|title|aliases
TASK_CATALOG=(
  "ssh||SSH connectivity|ssh,ssh connectivity,connectivity"
  "ports|ssh|Port matrix|ports,port matrix,port-matrix,mesh"
  "cascade||Client cascade (VIP → LB → mongos → mongod)|cascade,client cascade,vip cascade"
  "vip|ssh|VIP ownership|vip,vip ownership,vip-owner"
  "services|ssh|MongoDB systemd units|services,service,systemd,mongod"
  "membership|ssh|Replica set membership|membership,rs,replica,members"
  "primary|ssh|Primary / election|primary,election,leader"
  "lag|ssh|Replication lag|lag,replication lag,optime"
  "latency|ssh|Query latency (checker vs PRIMARY)|latency,ping,query latency,rtt"
  "disk|ssh|dbPath disk|disk,dbpath,dbPath"
  "oplog|ssh|Oplog window|oplog,oplog window"
  "shard|ssh|Sharded balancer / shards|shard,sharded,balancer"
  "config|ssh|Config drift (EXPECT_*)|config,config drift,drift,expect"
  "capacity|ssh|Capacity (FD / connections / WT)|capacity,fd,connections,wiredtiger"
  "os|ssh|OS health & security|os,os health,os health & security,os_security,security,boot"
)
TASKS_LIST_EXAMPLES="  $(basename "$0") -c CONFIG.env --only os
  $(basename "$0") -c CONFIG.env --only \"OS health & security\"
  $(basename "$0") -c CONFIG.env --only os,ports,cascade
  $(basename "$0") -c CONFIG.env --skip lag,capacity
  $(basename "$0") -c CONFIG.env --ask-tasks"

run_selected_tasks() {
  tasks_selected ssh && run_ssh_sweep
  tasks_selected ports && run_port_matrix
  tasks_selected cascade && run_mongo_cascade
  if tasks_selected vip; then
    if [[ -n "${VIP_HOST:-}" ]]; then
      check_vip_owner
    else
      record_check "vip" "skipped" "INFO" "VIP_HOST empty — VIP ownership not checked"
    fi
  fi
  tasks_selected services && check_mongo_services
  tasks_selected membership && check_mongo_membership
  tasks_selected primary && check_mongo_primary
  tasks_selected lag && check_mongo_lag
  tasks_selected latency && check_mongo_query_latency
  tasks_selected disk && check_mongo_disk_dbpath
  tasks_selected oplog && check_mongo_oplog
  tasks_selected shard && check_mongo_sharded
  tasks_selected config && check_mongo_config_drift
  tasks_selected capacity && check_mongo_capacity
  tasks_selected os && check_all_os_security
}

usage() {
  cat <<EOF
Usage: $(basename "$0") -c CONFIG.env [options]

MongoDB HA Health Check v${SCRIPT_VERSION}

Options:
  -c, --config FILE     Cluster inventory (.env)
  -u, --user USER       SSH username (skip prompt)
  -n, --no-sudo         Do not use sudo on remotes
  --only TASKS          Run only these tasks (comma-separated ids or titles)
  --skip TASKS          Skip these tasks (comma-separated)
  --ask-tasks           Interactively pick tasks before running
  --list-tasks          List task ids / titles / aliases and exit
  --json                Emit JSON summary at end
  -o, --report FILE     Write report to FILE (default: reports/mongoaha-*.log)
  -v, --verbose         Verbose details
  -y, --yes             Non-interactive (use defaults / env)
  -h, --help            Show help

Examples:
  $(basename "$0") -c config/clusters/devmongo.env -u USER -y --only os
  $(basename "$0") -c config/clusters/devmongo.env --only membership,primary,lag
  $(basename "$0") -c config/clusters/devmongo.env --ask-tasks

Exit codes: 0=PASS, 1=WARN/SLOW, 2=FAIL
Orchestrator: ./run_all.sh
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config) CONFIG_FILE="$2"; shift 2 ;;
      -u|--user) SSH_USER_OVERRIDE="$2"; shift 2 ;;
      -n|--no-sudo) USE_SUDO=0; shift ;;
      --only) ONLY_TASKS="$2"; shift 2 ;;
      --skip) SKIP_TASKS="$2"; shift 2 ;;
      --ask-tasks) ASK_TASKS=1; shift ;;
      --list-tasks) LIST_TASKS=1; shift ;;
      --json) JSON_OUT=1; shift ;;
      -o|--report) REPORT_FILE_OVERRIDE="$2"; shift 2 ;;
      -v|--verbose) VERBOSE=1; shift ;;
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
  if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "${ROOT_DIR}/${CONFIG_FILE}" ]]; then
      CONFIG_FILE="${ROOT_DIR}/${CONFIG_FILE}"
    else
      loge "Config not found: $CONFIG_FILE"; exit 2
    fi
  fi
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
}

require_local_bins() {
  local missing=0
  have_cmd ssh || { loge "Required command not found: ssh"; missing=1; }
  (( missing == 0 )) || exit 2
  have_cmd nc || have_cmd timeout || have_cmd telnet || {
    loge "Need nc, timeout, or telnet for TCP checks"; exit 2
  }
}

run_ssh_sweep() {
  section "SSH connectivity (telnet/tcp → SSH, PASS / SLOW / FAIL)"
  emit "  ${C_DIM}SLOW≥${SSH_SLOW_WARN_MS:-3000}ms; retry timeout=${SSH_RETRY_TIMEOUT_SEC:-35}s if port open but SSH fails${C_RESET}"
  local hosts=() all=() h seen="|"

  _ssh_add() {
    local role="$1" csv="$2" arr=()
    csv_to_array arr "$csv"
    for h in "${arr[@]}"; do
      [[ -z "$h" || "$seen" == *"|${h}|"* ]] && continue
      seen+="${h}|"
      all+=("${role}:$h|$h")
    done
  }

  _ssh_add "lb" "${LB_HOSTS:-}"
  _ssh_add "mongod" "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}"
  _ssh_add "mongos" "${MONGOS_HOSTS:-}"
  _ssh_add "configsvr" "${CONFIGSVR_HOSTS:-}"

  if [[ ${#all[@]} -eq 0 ]]; then
    record_check "ssh" "hosts" "FAIL" "MONGOD_HOSTS/MONGO_HOSTS empty in inventory"
    return
  fi

  _ssh_one() {
    local spec="$1"
    local label="${spec%%|*}"
    local host="${spec#*|}"
    check_ssh_host "$host" "$label"
  }
  run_parallel_fn _ssh_one "${all[@]}"
}

main() {
  parse_args "$@"

  if [[ "$LIST_TASKS" == "1" ]]; then
    tasks_list
    exit 0
  fi

  load_config
  require_local_bins

  if [[ "$ASK_TASKS" == "1" && "$NONINTERACTIVE" == "1" ]]; then
    loge "--ask-tasks cannot be used with -y/--yes"; exit 2
  fi
  if [[ "$ASK_TASKS" != "1" ]]; then
    if [[ -n "${ONLY_TASKS:-}" ]]; then
      local _pre=()
      tasks_parse_csv_to_array _pre "$ONLY_TASKS" || exit 2
    fi
    if [[ -n "${SKIP_TASKS:-}" ]]; then
      local _pres=()
      tasks_parse_csv_to_array _pres "$SKIP_TASKS" || exit 2
    fi
  fi

  init_result_store
  init_ssh_status_store
  init_parallel_store
  install_interrupt_traps
  init_report_file "${REPORT_FILE_OVERRIDE}"

  emit "${C_BOLD}MongoDB HA Health Check v${SCRIPT_VERSION}${C_RESET} — ${CLUSTER_NAME:-cluster}"
  emit "Config: ${CONFIG_FILE}"
  emit "Time:   $(date -Is)"
  resolve_parallel_jobs 0
  emit "Parallel jobs: ${PARALLEL_JOBS:-8}"

  tasks_select || exit $?
  prompt_credentials
  mongo_resolve_credentials

  set +e
  run_selected_tasks
  set -e

  local rc=0
  print_summary || rc=$?
  if [[ -n "${REPORT_FILE:-}" ]]; then
    {
      echo "----------------------------------------"
      echo "Finished: $(date -Is)"
      echo "Exit: ${rc}"
    } >> "$REPORT_FILE"
  fi
  exit "$rc"
}

main "$@"
