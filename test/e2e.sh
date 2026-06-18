#!/usr/bin/env bash
#
# Castellan - full end-to-end test cycle against the disposable Hyper-V VM.
#
# Proves the whole pipeline on a real systemd target, with every step asserted:
#
#   1. cold audit          degrades gracefully (failed=0)
#   2. apply               failed=0, no lockout (Play 4 reached)
#   3. post-apply audit    0 FAIL in the dashboard
#   4. re-apply            idempotent (changed=0)
#   5. check.sh            all green
#   6. fresh admin login   a brand-new SSH session: login + sudo OK
#   7. rollback            restores without lockout
#
# The VM is reverted to its 'clean-baseline' checkpoint BEFORE step 1 and AFTER
# step 7, so the run starts and ends on a pristine target (see test/vm-reset.sh).
#
# Usage:
#   ./test/e2e.sh                 full cycle, reset before and after
#   SKIP_RESET=1 ./test/e2e.sh    assume the VM is already clean, no checkpoint
#   KEEP_VM=1   ./test/e2e.sh     reset before, but leave the VM as-is at the end
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# Editable VM config (test/vm.env); exported env vars still win over its defaults.
# shellcheck source=test/vm.env
[ -f "${HERE}/vm.env" ] && . "${HERE}/vm.env"

HOST="${CASTELLAN_HOST:-192.168.1.43}"
PORT="${CASTELLAN_PORT:-22}"          # ssh_port stays 22 on the VM inventory
ADMIN="${CASTELLAN_ADMIN:-castellan}"
INIT_USER="${CASTELLAN_INIT_USER:-lucas}"
KEY="${HERE}/secrets/id_test"
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/castellan-e2e.XXXXXX")"

# ---- output helpers --------------------------------------------------------
if [ -t 1 ]; then C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_BLU=$'\033[0;34m'; C_RST=$'\033[0m'
else C_RED=''; C_GRN=''; C_BLU=''; C_RST=''; fi
step()  { printf '\n%s== Step %s ==%s\n' "${C_BLU}" "$*" "${C_RST}"; }
pass()  { printf '%s[+]%s %s\n' "${C_GRN}" "${C_RST}" "$*"; }
fail()  { printf '%s[x]%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; FAILED=1; }

FAILED=0

# Strip ANSI colour codes so PLAY RECAP parsing is reliable.
decolor() { sed -r 's/\x1b\[[0-9;]*m//g' "$1"; }

# Pull a numeric field (ok/changed/failed/unreachable) off the VM's recap line.
recap_field() { # <logfile> <field>
  decolor "$1" | grep -E "^${HOST}[[:space:]]*:" | tail -1 \
    | grep -oE "$2=[0-9]+" | head -1 | cut -d= -f2
}

# Run a harden mode through the VM wrapper, tee-ing to a per-step log.
run_mode() { # <logfile> <audit|apply|rollback> [extra args...]
  local log="$1"; shift
  ( cd "${ROOT}" && ./test/run-vm.sh "$@" ) 2>&1 | tee "${log}"
  return "${PIPESTATUS[0]}"
}

# A single, fresh SSH session (no ControlMaster) as a given user.
ssh_one() { # <user> <remote command...>
  local user="$1"; shift
  ssh -p "${PORT}" -i "${KEY}" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes -o ConnectTimeout=10 "${user}@${HOST}" "$@" 2>/dev/null
}

reset_vm() { # <when label>
  [ "${SKIP_RESET:-0}" = 1 ] && { pass "VM reset skipped ($1): SKIP_RESET=1"; return 0; }
  step "VM reset ($1) -> clean-baseline"
  if "${HERE}/vm-reset.sh"; then
    pass "VM reverted to clean-baseline and reachable"
  else
    fail "VM reset failed ($1) - is the CastellanVMReset task registered? (test/README.md)"
    return 1
  fi
}

echo "Castellan end-to-end cycle"
echo "  target : ${ADMIN}@${HOST}:${PORT} (initial user: ${INIT_USER})"
echo "  logs   : ${LOGDIR}"

# ---------------------------------------------------------------------------
reset_vm "before" || { echo "Aborting: cannot start from a clean VM." >&2; exit 1; }

# 1. Cold audit: must degrade gracefully (admin not created yet) with failed=0.
step "1. Cold audit (graceful degradation)"
run_mode "${LOGDIR}/1-audit.log" audit
f="$(recap_field "${LOGDIR}/1-audit.log" failed)"; u="$(recap_field "${LOGDIR}/1-audit.log" unreachable)"
if [ "${f:-x}" = 0 ] && [ "${u:-x}" = 0 ]; then pass "cold audit: failed=0 unreachable=0"
else fail "cold audit: failed=${f:-?} unreachable=${u:-?} (want 0/0)"; fi

# 2. Apply: failed=0, no lockout -> Play 4 (Report) must be reached.
step "2. Apply (no lockout, Play 4 reached)"
run_mode "${LOGDIR}/2-apply.log" apply
f="$(recap_field "${LOGDIR}/2-apply.log" failed)"; u="$(recap_field "${LOGDIR}/2-apply.log" unreachable)"
[ "${f:-x}" = 0 ] && [ "${u:-x}" = 0 ] \
  && pass "apply: failed=0 unreachable=0" \
  || fail "apply: failed=${f:-?} unreachable=${u:-?} (want 0/0)"
if decolor "${LOGDIR}/2-apply.log" | grep -qE 'PLAY \[Castellan \| Play 4 - Report\]'; then
  pass "apply: Play 4 (Report) reached -> no mid-pipeline lockout"
else
  fail "apply: Play 4 (Report) NOT reached -> possible lockout before the end"
fi

# 3. Post-apply audit: the dashboard must show 0 FAIL.
step "3. Post-apply audit (0 FAIL in dashboard)"
run_mode "${LOGDIR}/3-audit.log" audit
f="$(recap_field "${LOGDIR}/3-audit.log" failed)"
nfail="$(decolor "${LOGDIR}/3-audit.log" | grep -wc 'FAIL')"
[ "${f:-x}" = 0 ] || fail "post-apply audit: failed=${f:-?} (want 0)"
if [ "${nfail}" = 0 ]; then pass "post-apply audit: 0 FAIL in the dashboard"
else
  fail "post-apply audit: ${nfail} FAIL line(s) in the dashboard"
  decolor "${LOGDIR}/3-audit.log" | grep -w 'FAIL' | sed 's/^/      /' >&2
fi

# 4. Re-apply: must be idempotent (no config drift).
step "4. Re-apply (idempotent)"
run_mode "${LOGDIR}/4-reapply.log" apply
f="$(recap_field "${LOGDIR}/4-reapply.log" failed)"; c="$(recap_field "${LOGDIR}/4-reapply.log" changed)"
[ "${f:-x}" = 0 ] || fail "re-apply: failed=${f:-?} (want 0)"
if [ "${c:-x}" = 0 ]; then pass "re-apply: changed=0 (idempotent)"
else
  fail "re-apply: changed=${c:-?} (config drift - not idempotent)"
  decolor "${LOGDIR}/4-reapply.log" | grep -E '^changed: ' | sed 's/^/      /' >&2
fi

# 5. Effectiveness checks: all green.
step "5. check.sh (effectiveness, all green)"
if CASTELLAN_HOST="${HOST}" CASTELLAN_PORT="${PORT}" CASTELLAN_ADMIN="${ADMIN}" \
   "${HERE}/check.sh" | tee "${LOGDIR}/5-check.log"; then
  pass "check.sh: all checks passed"
else
  fail "check.sh: some checks failed"
fi

# 6. Fresh admin login: a brand-new SSH session must log in and sudo.
step "6. Fresh admin reconnection (login + sudo)"
who="$(ssh_one "${ADMIN}" 'whoami')"
uid="$(ssh_one "${ADMIN}" 'sudo -n id -u')"
if [ "${who}" = "${ADMIN}" ] && [ "${uid}" = 0 ]; then
  pass "fresh login: whoami=${who}, sudo -> uid 0"
else
  fail "fresh login: whoami='${who}' (want ${ADMIN}), sudo uid='${uid}' (want 0)"
fi

# 7. Rollback: restores without locking us out.
step "7. Rollback (restore without lockout)"
run_mode "${LOGDIR}/7-rollback.log" rollback
f="$(recap_field "${LOGDIR}/7-rollback.log" failed)"; u="$(recap_field "${LOGDIR}/7-rollback.log" unreachable)"
[ "${f:-x}" = 0 ] && [ "${u:-x}" = 0 ] \
  && pass "rollback: failed=0 unreachable=0" \
  || fail "rollback: failed=${f:-?} unreachable=${u:-?} (want 0/0)"
# Anti-lockout proof: the target must still be reachable over SSH after rollback.
if ssh_one "${ADMIN}" 'true' || ssh_one "${INIT_USER}" 'true'; then
  pass "rollback: target still reachable over SSH (no lockout)"
else
  fail "rollback: target unreachable over SSH (possible lockout)"
fi

# ---------------------------------------------------------------------------
if [ "${KEEP_VM:-0}" = 1 ]; then
  echo; pass "KEEP_VM=1: leaving the VM in its post-rollback state"
else
  reset_vm "after"
fi

echo
if [ "${FAILED}" -eq 0 ]; then
  printf '%s== END-TO-END CYCLE PASSED ==%s  (logs: %s)\n' "${C_GRN}" "${C_RST}" "${LOGDIR}"
else
  printf '%s== END-TO-END CYCLE FAILED ==%s  (logs: %s)\n' "${C_RED}" "${C_RST}" "${LOGDIR}"
fi
exit "${FAILED}"
