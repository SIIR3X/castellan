#!/usr/bin/env bash
#
# Post-apply effectiveness checks for the accounts + verify-access spine.
# Connects as the NEW admin and asserts the hardening actually took effect.
# Exit 0 = all checks passed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${HERE}/secrets/id_test"
# Target defaults to the podman container; override for the VM, e.g.
#   CASTELLAN_HOST=192.168.1.43 CASTELLAN_PORT=22 ./test/check.sh
HOST="${CASTELLAN_HOST:-127.0.0.1}"
PORT="${CASTELLAN_PORT:-2222}"
ADMIN="${CASTELLAN_ADMIN:-castellan}"
# Share a single SSH connection across all checks (ControlMaster), so the
# rapid sequence does not trip ufw's SSH rate-limit (limit = 6 conns / 30s).
SSH=(ssh -p "${PORT}" -i "${KEY}" -o StrictHostKeyChecking=accept-new
     -o UserKnownHostsFile=/dev/null
     -o ControlMaster=auto -o ControlPersist=30s
     -o ControlPath="/tmp/castellan-check-%r@%h:%p" "${ADMIN}@${HOST}")

fail=0
check() {
  local desc="$1" expected="$2"; shift 2
  local got; got="$("${SSH[@]}" "$@" 2>/dev/null)"
  if [ "${got}" = "${expected}" ]; then
    printf '[+] %-40s -> %s\n' "${desc}" "${got}"
  else
    printf '[x] %-40s -> got=%q want=%q\n' "${desc}" "${got}" "${expected}"
    fail=1
  fi
}

echo "== Effectiveness checks (as ${ADMIN}@${HOST}:${PORT}) =="
check "admin can log in (whoami)"        "${ADMIN}" 'whoami'
check "sudo escalates to root (uid 0)"   "0"        'sudo id -u'
check "member of sudo group"             "yes"      'id -nG | grep -qw sudo && echo yes || echo no'
check "member of ssh-users group"        "yes"      'id -nG | grep -qw ssh-users && echo yes || echo no'
check "sudoers drop-in installed"        "ok"       'test -f /etc/sudoers.d/castellan-castellan && echo ok || echo no'
check "backup directory created"         "ok"       'sudo test -d /var/backups/castellan && echo ok || echo no'

if [ "${fail}" -eq 0 ]; then
  echo "[+] ALL CHECKS PASSED"
else
  echo "[x] SOME CHECKS FAILED"
fi
exit "${fail}"
