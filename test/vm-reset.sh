#!/usr/bin/env bash
#
# Revert the disposable Hyper-V VM to its 'clean-baseline' checkpoint from WSL.
#
# Hyper-V cmdlets need an ELEVATED PowerShell, which WSL is not. So this script
# triggers a pre-authorized Windows scheduled task ('CastellanVMReset') that
# runs the restore elevated under the user's stored credentials - no UAC prompt.
#
# Register the task ONCE in an elevated PowerShell (see test/README.md):
#   powershell -ExecutionPolicy Bypass -File test\vm-reset-setup.ps1 -VMName '<name>'
#
# Then this script (and `make test`) can reset the target unattended.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Editable VM config (test/vm.env); exported env vars still win over its defaults.
# shellcheck source=test/vm.env
[ -f "${HERE}/vm.env" ] && . "${HERE}/vm.env"

TASK="${CASTELLAN_VM_RESET_TASK:-CastellanVMReset}"
HOST="${CASTELLAN_HOST:-192.168.1.43}"
PORT="${CASTELLAN_PORT:-22}"
INIT_USER="${CASTELLAN_INIT_USER:-lucas}"
KEY="${HERE}/secrets/id_test"
TIMEOUT="${CASTELLAN_RESET_TIMEOUT:-180}"

log() { printf '[vm-reset] %s\n' "$*"; }

# 1. The scheduled task must exist (created once, elevated).
if ! schtasks.exe /query /tn "${TASK}" >/dev/null 2>&1; then
  cat >&2 <<EOF
[vm-reset] Scheduled task '${TASK}' not found.
Create it ONCE in an elevated PowerShell, from the repo root:
  powershell -ExecutionPolicy Bypass -File test\\vm-reset-setup.ps1 -VMName '<your-vm-name>'
Then re-run. (Details: test/README.md)
EOF
  exit 2
fi

# 2. Trigger the restore (returns immediately; the task runs async).
log "Triggering '${TASK}' (revert clean-baseline + start VM)..."
schtasks.exe /run /tn "${TASK}" >/dev/null

# 3. Wait until the VM is back and accepts SSH as the initial user.
log "Waiting for ${HOST}:${PORT} to accept SSH (timeout ${TIMEOUT}s)..."
deadline=$(( $(date +%s) + TIMEOUT ))
until ssh -p "${PORT}" -i "${KEY}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=5 \
        "${INIT_USER}@${HOST}" 'true' 2>/dev/null; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    log "VM did not become reachable within ${TIMEOUT}s."
    exit 1
  fi
  sleep 5
done

log "VM reverted to clean-baseline and reachable as ${INIT_USER}."
