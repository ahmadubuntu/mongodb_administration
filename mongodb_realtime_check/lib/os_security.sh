#!/usr/bin/env bash
# OS resources, package updates, and light security signals.

# Set by check_boot_integrity when /var/lib/dpkg is not the real database, so the
# update checks can say why their answer is meaningless instead of reporting "0 upgrades".
MONGOAHA_DPKG_BROKEN=0

# A failed mount unit cascades much further than a missing filesystem: local-fs.target
# never completes, systemd-logind (Requires=var.mount) never starts, and from then on
# every PAM login blocks for the full 25s D-Bus activation timeout of
# org.freedesktop.login1 — which looks exactly like "SSH to this host is slow".
_boot_integrity_probe() {
  cat <<'PROBE'
mnt=$(findmnt -rn -o TARGET 2>/dev/null)
while read -r src tgt fs opts freq pass rest; do
  case "$src" in ""|\#*) continue;; esac
  case "$fs" in swap|nfs|nfs4|cifs|tmpfs|proc|sysfs|devtmpfs|devpts) continue;; esac
  case "$tgt" in ""|none|swap) continue;; esac
  printf "%s\n" "$mnt" | grep -qxF "$tgt" || echo "unmounted|$tgt|$src|$fs"
  # passno=0 → systemd-fsck never runs this mount at boot; errors can linger forever.
  echo "fstab_pass|$tgt|$src|$fs|${pass:-0}"
done < /etc/fstab

echo "target|local-fs|$(systemctl is-active local-fs.target 2>/dev/null)"
echo "target|multi-user|$(systemctl is-active multi-user.target 2>/dev/null)"
echo "target|logind|$(systemctl is-active systemd-logind 2>/dev/null)"
echo "logind_pam|$(journalctl -b -n 20000 --no-pager 2>/dev/null | grep -c "org.freedesktop.login1.*timed out")"

echo "timesync|chrony=$(systemctl is-active chrony 2>/dev/null) ntpsec=$(systemctl is-active ntpsec 2>/dev/null) timesyncd=$(systemctl is-active systemd-timesyncd 2>/dev/null)"
echo "dpkg|$(stat -c %s /var/lib/dpkg/status 2>/dev/null)|$(ls /var/lib/dpkg/info 2>/dev/null | wc -l)"

devs=$(
  { findmnt -rn -t ext4 -o SOURCE 2>/dev/null
    while read -r s t f o r; do
      case "$s" in ""|\#*) continue;; esac
      [ "$f" = ext4 ] && echo "$s"
    done < /etc/fstab
  } | while read -r d; do readlink -f "$d" 2>/dev/null; done | sort -u
)
for d in $devs; do
  [ -b "$d" ] || continue
  info=$(dumpe2fs -h "$d" 2>/dev/null)
  [ -n "$info" ] || continue
  st=$(printf "%s\n" "$info" | sed -n "s/^Filesystem state:[[:space:]]*//p")
  ec=$(printf "%s\n" "$info" | sed -n "s/^FS Error count:[[:space:]]*//p")
  le=$(printf "%s\n" "$info" | sed -n "s/^Last error time:[[:space:]]*//p")
  lm=$(printf "%s\n" "$info" | sed -n "s/^Last mounted on:[[:space:]]*//p")
  echo "fs|$d|${lm:-?}|${st:-?}|${ec:-0}|${le:-?}"
done
PROBE
}

check_boot_integrity() {
  local host="$1"
  local out
  out=$(remote_run "$host" 1 "$(_boot_integrity_probe)" 2>/dev/null) || true
  if [[ -z "${out// }" ]]; then
    record_check "os" "boot:${host}" "SKIP" "Could not read mount/unit state (needs sudo)"
    return
  fi

  local unmounted logind localfs multiuser pam_fails
  unmounted=$(printf '%s\n' "$out" | awk -F'|' '$1=="unmounted" {printf "%s(%s) ", $2, $3}')
  localfs=$(printf '%s\n' "$out" | awk -F'|' '$1=="target" && $2=="local-fs" {print $3}')
  multiuser=$(printf '%s\n' "$out" | awk -F'|' '$1=="target" && $2=="multi-user" {print $3}')
  logind=$(printf '%s\n' "$out" | awk -F'|' '$1=="target" && $2=="logind" {print $3}')
  pam_fails=$(printf '%s\n' "$out" | awk -F'|' '$1=="logind_pam" {print $2}')

  if [[ -n "${unmounted// }" ]]; then
    record_check "os" "mounts:${host}" "FAIL" \
      "fstab entries not mounted: ${unmounted}— writes are landing on the parent filesystem and every unit that Requires this mount stays down; inspect with 'systemctl list-units --failed' and fsck the device"
  else
    record_check "os" "mounts:${host}" "PASS" "All fstab filesystems mounted"
  fi

  if [[ "$localfs" == "active" && "$multiuser" == "active" ]]; then
    record_check "os" "boot_targets:${host}" "PASS" "local-fs.target and multi-user.target active"
  else
    record_check "os" "boot_targets:${host}" "FAIL" \
      "boot never completed: local-fs.target=${localfs:-?} multi-user.target=${multiuser:-?} — services that order after them may never have started"
  fi

  if [[ "$logind" == "active" ]]; then
    record_check "os" "logind:${host}" "PASS" "systemd-logind active — logins are not blocked"
  elif [[ -n "$logind" ]]; then
    local extra=""
    [[ "$pam_fails" =~ ^[0-9]+$ ]] && (( pam_fails > 0 )) && \
      extra=" (${pam_fails} pam_systemd 'org.freedesktop.login1 timed out' events this boot)"
    record_check "os" "logind:${host}" "FAIL" \
      "systemd-logind=${logind} — every ssh/su login waits out the 25s D-Bus activation timeout for org.freedesktop.login1${extra}. This is the usual cause of slow SSH here; logind Requires the mount units above"
  fi

  local ts
  ts=$(printf '%s\n' "$out" | awk -F'|' '$1=="timesync" {print $2}')
  if printf '%s' "$ts" | grep -q '=active'; then
    record_check "os" "timesync_unit:${host}" "PASS" "${ts}"
  elif [[ -n "${ts// }" ]]; then
    record_check "os" "timesync_unit:${host}" "WARN" "no time sync daemon running — ${ts}"
  fi

  local dpkg_bytes dpkg_files
  dpkg_bytes=$(printf '%s\n' "$out" | awk -F'|' '$1=="dpkg" {print $2}')
  dpkg_files=$(printf '%s\n' "$out" | awk -F'|' '$1=="dpkg" {print $3}')
  if [[ "$dpkg_bytes" =~ ^[0-9]+$ ]] && (( dpkg_bytes < 1000 )); then
    MONGOAHA_DPKG_BROKEN=1
    record_check "security" "dpkg_db:${host}" "FAIL" \
      "/var/lib/dpkg/status is ${dpkg_bytes} bytes (info files=${dpkg_files:-?}) — the package database is not the real one, so update/security reporting is meaningless. Do not run apt install/upgrade until the correct /var is mounted"
  elif [[ "$dpkg_bytes" =~ ^[0-9]+$ ]]; then
    record_check "security" "dpkg_db:${host}" "PASS" "dpkg database present ($((dpkg_bytes / 1024)) KiB, ${dpkg_files} info files)"
  fi

  # fstab passno: 0 means never auto-fsck'd. Root should be 1; other local FS usually 2.
  local pass_warn=0 tgt src fs passno
  while IFS='|' read -r _ tgt src fs passno; do
    [[ -z "$tgt" ]] && continue
    [[ "$passno" =~ ^[0-9]+$ ]] || passno=0
    if (( passno == 0 )); then
      pass_warn=1
      record_check "os" "fsck_pass:${host}:${tgt}" "WARN" \
        "fstab passno=0 for ${tgt} (${src}, ${fs}) — systemd-fsck never checks this mount at boot; set pass to 1 (root) or 2 so dirty/error states are repaired before mount"
    fi
  done < <(printf '%s\n' "$out" | grep '^fstab_pass|')
  if (( pass_warn == 0 )) && printf '%s\n' "$out" | grep -q '^fstab_pass|'; then
    record_check "os" "fsck_pass:${host}" "PASS" "fstab passno set for local mounts (root=1 / others≥2)"
  fi

  local dev lastmnt state ecount etime
  local fs_err=0
  while IFS='|' read -r _ dev lastmnt state ecount etime; do
    [[ -z "$dev" ]] && continue
    local where="${lastmnt}"
    if [[ "$state" == *"with errors"* ]] || { [[ "$ecount" =~ ^[0-9]+$ ]] && (( ecount > 0 )); }; then
      fs_err=1
      record_check "os" "fs_errors:${host}:${where}" "FAIL" \
        "${dev} state='${state}' FS Error count=${ecount} last error ${etime} — stop services using ${where}, unmount it, run e2fsck -fy ${dev} (or fsck -y), remount; reboot alone will NOT clear this. If systemd-fsck then refuses with UNEXPECTED INCONSISTENCY, stay in maintenance / unmount and repair manually. Also ensure fstab passno≠0 so future boots run fsck"
    fi
  done < <(printf '%s\n' "$out" | grep '^fs|')
  if (( fs_err == 0 )) && printf '%s\n' "$out" | grep -q '^fs|'; then
    record_check "os" "fs_errors:${host}" "PASS" "ext4 filesystems report clean (FS Error count=0)"
  fi
}

check_os_host() {
  local host="$1" role="$2"
  local label="${role}:${host}"

  # Disk
  local disk
  disk=$(remote_run "$host" 0 "df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk 'NR>1 {gsub(/%/,\"\",\$5); printf \"%s %s\\n\", \$5, \$6}'" 2>&1) || true
  local pct mnt worst=0 worst_mnt=""
  while read -r pct mnt; do
    [[ -z "$pct" ]] && continue
    if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct > worst )); then
      worst=$pct
      worst_mnt=$mnt
    fi
    if [[ "$pct" =~ ^[0-9]+$ ]]; then
      if (( pct >= ${DISK_FAIL_PCT:-90} )); then
        record_check "os" "disk:${host}:${mnt}" "FAIL" "${pct}% used"
      elif (( pct >= ${DISK_WARN_PCT:-80} )); then
        record_check "os" "disk:${host}:${mnt}" "WARN" "${pct}% used"
      fi
    fi
  done <<<"$disk"
  if (( worst < ${DISK_WARN_PCT:-80} )); then
    record_check "os" "disk:${host}" "PASS" "Max disk usage ${worst}% (${worst_mnt:-/})"
  fi

  # Inodes
  local inodes
  inodes=$(remote_run "$host" 0 "df -Pi -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 {gsub(/%/,\"\",\$5); if(\$5+0>=80) print \$5,\$6}'" 2>&1) || true
  if [[ -n "${inodes// }" ]]; then
    record_check "os" "inode:${host}" "WARN" "High inode usage" "$inodes"
  else
    record_check "os" "inode:${host}" "PASS" "Inode usage OK"
  fi

  # Load / memory
  local load nproc mem
  load=$(remote_run "$host" 0 "awk '{print \$1}' /proc/loadavg" 2>&1) || load=0
  nproc=$(remote_run "$host" 0 "nproc" 2>&1) || nproc=1
  local ratio
  ratio=$(awk -v l="$load" -v n="$nproc" 'BEGIN{ if(n+0==0) n=1; printf "%.2f", l/n }')
  if float_ge "$ratio" "${LOAD_FAIL_RATIO:-3.0}"; then
    record_check "os" "load:${host}" "FAIL" "load1=${load} nproc=${nproc} ratio=${ratio}"
  elif float_ge "$ratio" "${LOAD_WARN_RATIO:-1.5}"; then
    record_check "os" "load:${host}" "WARN" "load1=${load} nproc=${nproc} ratio=${ratio}"
  else
    record_check "os" "load:${host}" "PASS" "load1=${load} nproc=${nproc} ratio=${ratio}"
  fi

  mem=$(remote_run "$host" 0 "free -m | awk '/Mem:/{printf \"used=%d total=%d avail=%d\", \$3,\$2,\$7}'" 2>&1) || true
  record_check "os" "memory:${host}" "INFO" "${mem}"

  local swap
  swap=$(remote_run "$host" 0 "free -m | awk '/Swap:/{if(\$2==0) print \"none\"; else printf \"used=%d/%d\", \$3,\$2}'" 2>&1) || true
  if [[ "$swap" == used=* ]]; then
    local su st
    su=$(printf '%s' "$swap" | sed -n 's/used=\([0-9]*\)\/.*/\1/p')
    st=$(printf '%s' "$swap" | sed -n 's/used=[0-9]*\/\([0-9]*\)/\1/p')
    if [[ -n "$su" && -n "$st" && "$st" -gt 0 && $((su * 100 / st)) -ge 50 ]]; then
      record_check "os" "swap:${host}" "WARN" "$swap"
    else
      record_check "os" "swap:${host}" "PASS" "$swap"
    fi
  else
    record_check "os" "swap:${host}" "INFO" "swap=${swap}"
  fi

  # Time sync
  local timed
  timed=$(remote_run "$host" 0 "timedatectl show -p NTPSynchronized -p SystemClockSynchronized 2>&1 | head -5" 2>&1) || true
  if printf '%s' "$timed" | grep -Eqi 'NTPSynchronized=yes|System clock synchronized: yes'; then
    record_check "os" "ntp:${host}" "PASS" "Clock synchronized"
  elif printf '%s' "$timed" | grep -Eqi 'Failed to query server|Connection timed out|Failed to connect to bus'; then
    # timedatectl talks to systemd over D-Bus; a timeout means the host itself is unhealthy
    record_check "os" "ntp:${host}" "WARN" "timedatectl could not reach systemd-timesyncd over D-Bus: ${timed//$'\n'/ } — check systemd-timesyncd/dbus on this host"
  elif [[ -n "$timed" ]]; then
    record_check "os" "ntp:${host}" "WARN" "Clock sync unclear" "$timed"
  else
    record_check "os" "ntp:${host}" "SKIP" "timedatectl unavailable"
  fi

  # OOM
  local oom
  oom=$(remote_run "$host" 1 "journalctl -k --since '7 days ago' 2>/dev/null | grep -i 'Out of memory' | tail -3" 2>&1) || true
  if [[ -n "${oom// }" && "$oom" != *"Permission"* ]]; then
    record_check "os" "oom:${host}" "WARN" "OOM traces in last 7 days" "$oom"
  else
    record_check "os" "oom:${host}" "PASS" "No recent OOM in journal (or not readable)"
  fi

  check_systemd_failed "$host" "failed@${host}"
  check_boot_integrity "$host"
}

check_updates_security() {
  local host="$1" role="$2"
  local allow=""

  case "$role" in
    haproxy|lb) allow="${ALLOW_PORTS_LB:-${ALLOW_PORTS_HAPROXY:-}}" ;;
    mongod|rs) allow="${ALLOW_PORTS_MONGOD:-${ALLOW_PORTS_MONGO:-}}" ;;
    mongos) allow="${ALLOW_PORTS_MONGOS:-${ALLOW_PORTS_MONGO:-}}" ;;
    configsvr) allow="${ALLOW_PORTS_CONFIGSVR:-${ALLOW_PORTS_MONGO:-}}" ;;
    backup) allow="${ALLOW_PORTS_BACKUP:-}" ;;
    vip) allow="${ALLOW_PORTS_VIP:-}" ;;
    *) allow="" ;;
  esac

  # Pending updates — a truncated dpkg database reports "nothing to upgrade",
  # so refuse to answer rather than emitting a false PASS.
  if [[ "${MONGOAHA_DPKG_BROKEN}" == "1" ]]; then
    record_check "security" "updates:${host}" "SKIP" \
      "not checked — dpkg database is broken on this host (see dpkg_db check); apt would report nonsense"
  else
    local pending
    pending=$(remote_run "$host" 0 "/usr/lib/update-notifier/apt-check 2>&1" 2>&1) || true
    if [[ "$pending" =~ ^[0-9]+\;[0-9]+$ ]]; then
      local total sec
      total=${pending%%;*}
      sec=${pending##*;}
      if [[ "$sec" -gt 0 ]]; then
        record_check "security" "updates:${host}" "WARN" "${total} upgrades (${sec} security)"
      elif [[ "$total" -gt 0 ]]; then
        record_check "security" "updates:${host}" "INFO" "${total} pending upgrades (0 security)"
      else
        record_check "security" "updates:${host}" "PASS" "No pending upgrades"
      fi
    else
      pending=$(remote_run "$host" 1 "apt-get -s upgrade 2>/dev/null | awk '/^Inst /{c++} END{print c+0}'" 2>&1) || pending=""
      if [[ "$pending" =~ ^[0-9]+$ ]]; then
        if [[ "$pending" -gt 0 ]]; then
          record_check "security" "updates:${host}" "INFO" "${pending} simulated upgrades (apt-get -s)"
        else
          record_check "security" "updates:${host}" "PASS" "No pending upgrades (apt-get -s)"
        fi
      else
        record_check "security" "updates:${host}" "SKIP" "Could not determine pending updates"
      fi
    fi
  fi

  # Reboot required
  local reboot
  reboot=$(remote_run "$host" 0 "test -f /var/run/reboot-required && echo yes || echo no" 2>&1) || reboot="?"
  if [[ "$reboot" == "yes" ]]; then
    local pkgs
    pkgs=$(remote_run "$host" 0 "cat /var/run/reboot-required.pkgs 2>/dev/null | head -10" 2>&1) || true
    record_check "security" "reboot:${host}" "WARN" "Reboot required" "$pkgs"
  else
    record_check "security" "reboot:${host}" "PASS" "No reboot-required flag"
  fi

  # sshd settings
  local sshd
  sshd=$(remote_run "$host" 1 "sshd -T 2>/dev/null | awk 'tolower(\$1)==\"permitrootlogin\"||tolower(\$1)==\"passwordauthentication\"{print}'" 2>&1) || true
  if [[ -n "$sshd" ]]; then
    local prl pa
    prl=$(printf '%s\n' "$sshd" | awk 'tolower($1)=="permitrootlogin"{print $2}')
    pa=$(printf '%s\n' "$sshd" | awk 'tolower($1)=="passwordauthentication"{print $2}')
    if [[ "$prl" == "yes" ]]; then
      record_check "security" "sshd_root:${host}" "WARN" "PermitRootLogin yes"
    else
      record_check "security" "sshd_root:${host}" "PASS" "PermitRootLogin ${prl:-unknown}"
    fi
    record_check "security" "sshd_passauth:${host}" "INFO" "PasswordAuthentication ${pa:-unknown}"
  else
    record_check "security" "sshd:${host}" "SKIP" "sshd -T unavailable"
  fi

  # Unexpected listeners — report the owning process too, otherwise a bare port
  # number says nothing about whether it is legitimate.
  local listeners
  listeners=$(remote_run "$host" 1 "ss -lntup 2>/dev/null | awk 'NR>1{
      port=\$5; sub(/.*[:.]/, \"\", port)
      proc=\"?\"
      if (match(\$0, /users:\(\(\"[^\"]+/)) { proc=substr(\$0, RSTART+9, RLENGTH-9); gsub(/\"/, \"\", proc) }
      print port\"/\"proc
    }' | sort -u" 2>&1) || true
  if [[ -z "${listeners// }" ]]; then
    record_check "security" "listeners:${host}" "SKIP" "Could not list listening ports"
    return
  fi
  local allow_list="${allow},${ALLOW_PORTS_AGENTS:-},${SSH_PORT},22,53,68,111,323,631"
  local unexpected=()
  local entry port
  while read -r entry; do
    [[ -z "$entry" ]] && continue
    port="${entry%%/*}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    if [[ "$port" -ge 32768 ]]; then
      continue
    fi
    if ! printf ',%s,' "$allow_list" | grep -q ",${port},"; then
      unexpected+=("$entry")
    fi
  done <<<"$listeners"

  if [[ ${#unexpected[@]} -eq 0 ]]; then
    record_check "security" "listeners:${host}" "PASS" "No unexpected listening ports vs allowlist"
  else
    record_check "security" "listeners:${host}" "WARN" "Unexpected ports (port/process): $(join_by ' ' "${unexpected[@]}")"
  fi
}

check_all_os_security() {
  section "OS health & security"
  local hosts=() all=() seen="|"

  _add_role() {
    local role="$1" csv="$2" h
    local arr=()
    csv_to_array arr "$csv"
    for h in "${arr[@]}"; do
      [[ -z "$h" ]] && continue
      if [[ "$seen" == *"|${h}|"* ]]; then
        continue
      fi
      seen+="${h}|"
      all+=("${role}|${h}")
    done
  }

  _add_role "lb" "${LB_HOSTS:-}"
  _add_role "mongod" "${MONGOD_HOSTS:-${MONGO_HOSTS:-}}"
  _add_role "mongos" "${MONGOS_HOSTS:-}"
  _add_role "configsvr" "${CONFIGSVR_HOSTS:-}"
  if [[ -n "${VIP_HOST:-}" ]]; then
    all+=("vip|${VIP_HOST}")
  fi

  _os_one() {
    local spec="$1"
    local role="${spec%%|*}"
    local host="${spec#*|}"
    if ! ssh_host_is_ok "$host"; then
      if [[ "$role" == "vip" ]]; then
        record_check "os" "vip-host:${host}" "INFO" "floating address — OS checks run on LB/mongod nodes instead"
      else
        record_check "os" "${role}:${host}" "SKIP" "SSH unavailable"
      fi
      return
    fi
    check_os_host "$host" "$role"
    check_updates_security "$host" "$role"
  }
  if [[ ${#all[@]} -eq 0 ]]; then
    record_check "os" "hosts" "SKIP" "No MONGOD_HOSTS/LB_HOSTS in inventory"
    return
  fi
  run_parallel_fn _os_one "${all[@]}"
}
