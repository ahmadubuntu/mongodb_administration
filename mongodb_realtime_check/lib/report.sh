#!/usr/bin/env bash
# Aggregate report from result store files.

print_summary() {
  section "Summary"
  load_severity_from_store

  local pass=0 warn=0 fail=0 skip=0 info=0 slow=0
  local status category name message
  if [[ -n "${_RESULTS_FILE:-}" && -f "${_RESULTS_FILE}" ]]; then
    while IFS='|' read -r status category name message; do
      [[ -z "$status" ]] && continue
      case "$status" in
        PASS) pass=$((pass+1)) ;;
        WARN) warn=$((warn+1)) ;;
        SLOW) slow=$((slow+1)) ;;
        FAIL) fail=$((fail+1)) ;;
        SKIP) skip=$((skip+1)) ;;
        INFO) info=$((info+1)) ;;
      esac
    done < "${_RESULTS_FILE}"
  fi

  emit "  ${C_GREEN}PASS${C_RESET}=${pass}  ${C_YELLOW}WARN${C_RESET}=${warn}  ${C_MAGENTA}SLOW${C_RESET}=${slow}  ${C_RED}FAIL${C_RESET}=${fail}  INFO=${info}  SKIP=${skip}"

  if [[ -n "${REPORT_FILE:-}" ]]; then
    emit "  Report saved: ${REPORT_FILE}"
  fi

  if [[ "${JSON_OUT:-0}" == "1" ]]; then
    local first=1 buf row
    buf=$(printf '{"cluster":"%s","version":"%s","max_severity":%s,"counts":{"pass":%s,"warn":%s,"slow":%s,"fail":%s,"info":%s,"skip":%s},"report_file":"%s","checks":[' \
      "$(_json_escape "${CLUSTER_NAME:-unknown}")" "$(_json_escape "${SCRIPT_VERSION}")" "${_MAX_SEVERITY:-0}" \
      "$pass" "$warn" "$slow" "$fail" "$info" "$skip" "$(_json_escape "${REPORT_FILE:-}")")
    if [[ -f "${_RESULTS_FILE}.json" ]]; then
      while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        if (( first )); then first=0; else buf+=","; fi
        buf+="$row"
      done < "${_RESULTS_FILE}.json"
    fi
    buf+="]}"
    emit "$buf"
  fi

  case "${_MAX_SEVERITY:-0}" in
    0)
      logi "Cluster looks healthy."
      return 0
      ;;
    1)
      loge "Cluster has warnings/slow links — review above."
      return 1
      ;;
    *)
      loge "Cluster has failures — investigate immediately."
      return 2
      ;;
  esac
}
