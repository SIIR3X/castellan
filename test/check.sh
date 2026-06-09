#!/usr/bin/env bash
#
# Post-apply effectiveness checks for the accounts + verify-access spine.
# Connects as the NEW admin and asserts the hardening actually took effect.
# Exit 0 = all checks passed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${HERE}/secrets/id_test"
PORT=2222
ADMIN=castellan
SSH=(ssh -p "${PORT}" -i "${KEY}" -o StrictHostKeyChecking=accept-new
     -o UserKnownHostsFile=/dev/null "${ADMIN}@127.0.0.1")

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

echo "== Effectiveness checks (as ${ADMIN}) =="
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
