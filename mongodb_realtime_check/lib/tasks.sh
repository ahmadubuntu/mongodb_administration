#!/usr/bin/env bash
# Selective task runner helpers (--only / --skip / --ask-tasks / --list-tasks).
#
# Caller sets TASK_CATALOG entries as:
#   "id|prereqs|title|aliases"
# where:
#   id       — short token (matched exactly, case-insensitive)
#   prereqs  — empty or comma-separated task ids auto-enabled if missing
#   title    — human title (also matched)
#   aliases  — comma-separated alternate names
#
# Globals (caller may set before tasks_select):
#   ONLY_TASKS  SKIP_TASKS  ASK_TASKS  NONINTERACTIVE
#   TASKS_LIST_EXAMPLES  — optional multi-line examples appended by tasks_list
#
# After tasks_select:
#   SELECTED_TASKS  — space-separated ids in run order
#
# Requires: bash 4+. Uses emit/loge from common.sh when present.

SELECTED_TASKS="${SELECTED_TASKS:-}"
ONLY_TASKS="${ONLY_TASKS:-}"
SKIP_TASKS="${SKIP_TASKS:-}"
ASK_TASKS="${ASK_TASKS:-0}"
LIST_TASKS="${LIST_TASKS:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

_tasks_err() {
  if declare -F loge >/dev/null 2>&1; then
    loge "$*"
  else
    echo "ERROR: $*" >&2
  fi
}

_tasks_msg() {
  if declare -F emit >/dev/null 2>&1; then
    emit "$*"
  elif declare -F info >/dev/null 2>&1; then
    info "$*"
  else
    echo "$*"
  fi
}

_tasks_dim() {
  local t="$*"
  if declare -F emit >/dev/null 2>&1; then
    emit "${C_DIM:-}${t}${C_RESET:-}"
  else
    _tasks_msg "$t"
  fi
}

_task_ids() {
  local row
  for row in "${TASK_CATALOG[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

_task_field() {
  # field: 1=id 2=prereqs 3=title 4=aliases
  local want="$1" field="$2" row rest
  for row in "${TASK_CATALOG[@]}"; do
    [[ "${row%%|*}" == "$want" ]] || continue
    rest="$row"
    case "$field" in
      1) printf '%s' "${rest%%|*}"; return 0 ;;
      2) rest="${rest#*|}"; printf '%s' "${rest%%|*}"; return 0 ;;
      3) rest="${rest#*|}"; rest="${rest#*|}"; printf '%s' "${rest%%|*}"; return 0 ;;
      4) rest="${rest#*|}"; rest="${rest#*|}"; rest="${rest#*|}"; printf '%s' "$rest"; return 0 ;;
    esac
  done
  return 1
}

_norm_task_token() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g; s/^ +| +$//g; s/ +/ /g'
}

_alias_list() {
  local id="$1" aliases
  aliases="$(_task_field "$id" 4)"
  printf '%s\n' "${aliases//,/$'\n'}"
}

tasks_resolve_token() {
  local raw="$1" norm id title a
  local -a hits=()
  norm="$(_norm_task_token "$raw")"
  [[ -n "$norm" ]] || return 1

  while read -r id; do
    [[ "$norm" == "$id" ]] && { printf '%s' "$id"; return 0; }
  done < <(_task_ids)

  while read -r id; do
    title="$(_norm_task_token "$(_task_field "$id" 3)")"
    [[ "$norm" == "$title" ]] && { printf '%s' "$id"; return 0; }
    while read -r a; do
      [[ -z "$a" ]] && continue
      a="$(_norm_task_token "$a")"
      [[ "$norm" == "$a" ]] && { printf '%s' "$id"; return 0; }
    done < <(_alias_list "$id")
  done < <(_task_ids)

  if ((${#norm} >= 3)); then
    while read -r id; do
      title="$(_norm_task_token "$(_task_field "$id" 3)")"
      if [[ "$title" == *"$norm"* ]]; then
        hits+=("$id")
        continue
      fi
      while read -r a; do
        [[ -z "$a" ]] && continue
        a="$(_norm_task_token "$a")"
        ((${#a} < 3)) && continue
        if [[ "$a" == *"$norm"* || "$norm" == *"$a"* ]]; then
          hits+=("$id")
          break
        fi
      done < <(_alias_list "$id")
    done < <(_task_ids)
  fi

  if ((${#hits[@]} == 1)); then
    printf '%s' "${hits[0]}"
    return 0
  fi
  return 1
}

tasks_list() {
  cat <<EOF
Available tasks for --only / --skip (id — title):

EOF
  local id
  while read -r id; do
    printf '  %-14s  %s\n' "$id" "$(_task_field "$id" 3)"
    printf '                 aliases: %s\n' "$(_task_field "$id" 4)"
    local pr="$(_task_field "$id" 2)"
    [[ -n "$pr" ]] && printf '                 prereqs: %s\n' "$pr"
  done < <(_task_ids)
  if [[ -n "${TASKS_LIST_EXAMPLES:-}" ]]; then
    printf '\nExamples:\n%s\n' "$TASKS_LIST_EXAMPLES"
  fi
}

tasks_selected() {
  local id="$1"
  [[ " ${SELECTED_TASKS} " == *" ${id} "* ]]
}

tasks_parse_csv_to_array() {
  local -n _out=$1
  local csv="$2"
  local tok id bad=0
  local -a parts=()
  _out=()
  csv="${csv//;/,}"
  csv="${csv#"${csv%%[![:space:]]*}"}"
  csv="${csv%"${csv##*[![:space:]]}"}"
  [[ -n "$csv" ]] || return 0

  if [[ "$csv" != *,* ]]; then
    parts=("$csv")
  else
    while IFS= read -r tok; do
      parts+=("$tok")
    done < <(printf '%s' "$csv" | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^ +| +$/,"",$i); if($i!="") print $i}}')
  fi
  for tok in "${parts[@]}"; do
    [[ -z "$tok" ]] && continue
    id="$(tasks_resolve_token "$tok" || true)"
    if [[ -z "$id" ]]; then
      _tasks_err "Unknown task: '${tok}' (use --list-tasks)"
      bad=1
      continue
    fi
    _out+=("$id")
  done
  return "$bad"
}

_tasks_expand_prereqs_into() {
  # $1 = nameref of requested ids array → fills $2 nameref with expanded ordered ids
  local -n _req=$1
  local -n _out=$2
  local -a ordered=()
  local id p seen="|" prereqs requested_set="|"
  _out=()

  for id in "${_req[@]}"; do
    requested_set+="${id}|"
  done

  _ensure() {
    local tid="$1" q
    [[ "$seen" == *"|${tid}|"* ]] && return 0
    prereqs="$(_task_field "$tid" 2)"
    if [[ -n "$prereqs" ]]; then
      local -a plist=()
      IFS=',' read -ra plist <<<"$prereqs"
      for q in "${plist[@]}"; do
        q="${q// /}"
        [[ -z "$q" ]] && continue
        if ! _task_field "$q" 1 >/dev/null 2>&1; then
          _tasks_err "Invalid prereq '${q}' for task '${tid}'"
          return 1
        fi
        _ensure "$q" || return 1
      done
    fi
    if [[ "$seen" != *"|${tid}|"* ]]; then
      seen+="${tid}|"
      ordered+=("$tid")
      if [[ "$requested_set" != *"|${tid}|"* ]]; then
        _tasks_dim "Auto-enabled prerequisite task: ${tid}"
      fi
    fi
  }

  for id in "${_req[@]}"; do
    _ensure "$id" || return 1
  done
  _out=("${ordered[@]}")
}

tasks_select() {
  local -a ids=() skip=() filtered=() expanded=()
  local id s keep

  if [[ "${#TASK_CATALOG[@]}" -eq 0 ]]; then
    _tasks_err "TASK_CATALOG is empty"; return 2
  fi

  if [[ "$ASK_TASKS" == "1" ]]; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then
      _tasks_err "--ask-tasks cannot be used with -y/--yes"; return 2
    fi
    _tasks_msg "Select tasks to run (comma-separated ids/titles, or 'all')."
    tasks_list
    local ans=""
    read -r -p "Tasks [all]: " ans || true
    if [[ -z "$ans" || "$ans" == "all" ]]; then
      ONLY_TASKS=""
      SKIP_TASKS=""
    else
      ONLY_TASKS="$ans"
    fi
  fi

  if [[ -n "$ONLY_TASKS" ]]; then
    tasks_parse_csv_to_array ids "$ONLY_TASKS" || return 2
  else
    while read -r id; do ids+=("$id"); done < <(_task_ids)
  fi

  if [[ -n "$SKIP_TASKS" ]]; then
    tasks_parse_csv_to_array skip "$SKIP_TASKS" || return 2
    for id in "${ids[@]}"; do
      keep=1
      for s in "${skip[@]}"; do
        [[ "$id" == "$s" ]] && keep=0 && break
      done
      (( keep )) && filtered+=("$id")
    done
    ids=("${filtered[@]}")
  fi

  if ((${#ids[@]} == 0)); then
    _tasks_err "No tasks selected"; return 2
  fi

  _tasks_expand_prereqs_into ids expanded || return 2

  local IFS=' '
  SELECTED_TASKS="${expanded[*]}"
  _tasks_msg "Tasks: ${SELECTED_TASKS}"
  return 0
}

# Parse common task flags from argv; leftover args left in TASKS_REMAINING_ARGS.
# Usage: tasks_parse_args "$@" ; set -- "${TASKS_REMAINING_ARGS[@]}"
tasks_parse_args() {
  TASKS_REMAINING_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) ONLY_TASKS="$2"; shift 2 ;;
      --skip) SKIP_TASKS="$2"; shift 2 ;;
      --ask-tasks) ASK_TASKS=1; shift ;;
      --list-tasks) LIST_TASKS=1; shift ;;
      --) shift; TASKS_REMAINING_ARGS+=("$@"); break ;;
      *) TASKS_REMAINING_ARGS+=("$1"); shift ;;
    esac
  done
}
