#!/usr/bin/env bash
# Run all mongodb_realtime_check suites (HA today; add admin suites later).
#
# Usage:
#   ./run_all.sh -c config/clusters/devmongo.env -u USER -y
#   ./run_all.sh -c CONFIG.env -u USER -y --only ha
#   ./run_all.sh --list-tasks
#   ./run_all.sh -c CONFIG.env -u USER -y --only ha -- --only os
#
# Args after "--" are forwarded to child entrypoints.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="$(cat "${ROOT}/VERSION" 2>/dev/null | tr -d '[:space:]' || echo 0.0.0)"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/tasks.sh"

CONFIG_FILE=""
SSH_USER_OVERRIDE="${SSH_USER_OVERRIDE:-}"
NONINTERACTIVE=0
CHILD_ARGS=()

TASK_CATALOG=(
  "ha||HA cluster health check|ha,health,check_mongo_ha,mongo ha"
)
TASKS_LIST_EXAMPLES="  $(basename "$0") -c CONFIG.env -u USER -y
  $(basename "$0") -c CONFIG.env -u USER -y --only ha
  $(basename "$0") -c CONFIG.env -u USER -y --only ha -- --only os
  $(basename "$0") --ask-tasks"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [-- child-args...]

MongoDB realtime check orchestrator v${SCRIPT_VERSION}

Suites under this directory:
  ha       → ./check_mongo_ha.sh

(More suites can be added later; deep admin runners should be named
run_admin_suite.sh — never overload run_all to mean only admin.)

Options:
  -c, --config FILE   Cluster inventory (required for ha)
  -u, --user USER     SSH username (passed to ha)
  --only TASKS        Suites to run (default: all)
  --skip TASKS        Suites to skip
  --ask-tasks         Interactive suite picker
  --list-tasks        List suites and exit
  -y, --yes           Non-interactive
  -h, --help

Anything after "--" is forwarded to each selected child.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config) CONFIG_FILE="$2"; shift 2 ;;
      -u|--user) SSH_USER_OVERRIDE="$2"; shift 2 ;;
      --only) ONLY_TASKS="$2"; shift 2 ;;
      --skip) SKIP_TASKS="$2"; shift 2 ;;
      --ask-tasks) ASK_TASKS=1; shift ;;
      --list-tasks) LIST_TASKS=1; shift ;;
      -y|--yes) NONINTERACTIVE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; CHILD_ARGS+=("$@"); break ;;
      *) loge "Unknown argument: $1"; usage; exit 2 ;;
    esac
  done
}

_resolve_config() {
  if [[ -z "$CONFIG_FILE" ]]; then
    return 1
  fi
  if [[ ! -f "$CONFIG_FILE" && -f "${ROOT}/${CONFIG_FILE}" ]]; then
    CONFIG_FILE="${ROOT}/${CONFIG_FILE}"
  fi
  [[ -f "$CONFIG_FILE" ]]
}

_run_suite() {
  local id="$1"
  local -a cmd=()
  case "$id" in
    ha)
      if ! _resolve_config; then
        loge "ha requires -c/--config"; return 2
      fi
      cmd=("${ROOT}/check_mongo_ha.sh" -c "$CONFIG_FILE")
      [[ -n "$SSH_USER_OVERRIDE" ]] && cmd+=(-u "$SSH_USER_OVERRIDE")
      [[ "$NONINTERACTIVE" == "1" ]] && cmd+=(-y)
      cmd+=("${CHILD_ARGS[@]}")
      ;;
    *)
      loge "Unknown suite: $id"; return 2
      ;;
  esac

  section "Suite: ${id}"
  emit "Command: ${cmd[*]}"
  set +e
  "${cmd[@]}"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    emit "${C_GREEN}Suite ${id} finished OK (rc=0)${C_RESET}"
  else
    emit "${C_YELLOW}Suite ${id} finished with rc=${rc}${C_RESET}"
  fi
  return "$rc"
}

main() {
  parse_args "$@"

  if [[ "$LIST_TASKS" == "1" ]]; then
    tasks_list
    exit 0
  fi

  emit "${C_BOLD}mongodb_realtime_check orchestrator v${SCRIPT_VERSION}${C_RESET}"
  emit "Time: $(date -Is)"

  tasks_select || exit $?

  local -a selected=()
  read -r -a selected <<<"$SELECTED_TASKS"
  local id worst=0 rc
  for id in "${selected[@]}"; do
    rc=0
    _run_suite "$id" || rc=$?
    (( rc > worst )) && worst=$rc
  done

  section "Orchestrator complete"
  emit "Worst child exit: ${worst}"
  exit "$worst"
}

main "$@"
