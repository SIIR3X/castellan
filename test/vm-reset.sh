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
SETTLE_TIMEOUT="${CASTELLAN_SETTLE_TIMEOUT:-150}"

log() { printf '[vm-reset] %s\n' "$*"; }

# Run a command on the VM as the initial user (fresh connection each time).
ssh_vm() {
  ssh -p "${PORT}" -i "${KEY}" -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=8 \
      "${INIT_USER}@${HOST}" "$@" 2>/dev/null
}

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

# 4. Wait until the VM has finished BOOTING, not just opened :22. A freshly
# reverted checkpoint is still running cloud-init / late systemd units /
# unattended-upgrades; starting the audit+apply right away (dozens of SSH+sudo
# +apt operations) against a still-settling host causes transient SSH/sudo/dpkg
# failures. Wait for a steady state, then neutralize background apt jobs so they
# cannot grab the dpkg lock or load the VM mid-run.
log "Waiting for the VM to finish booting (settle, timeout ${SETTLE_TIMEOUT}s)..."
# cloud-init first (best effort: absent/disabled on some images, bounded).
ssh_vm 'command -v cloud-init >/dev/null 2>&1 && timeout 90 cloud-init status --wait >/dev/null 2>&1 || true'
settle_deadline=$(( $(date +%s) + SETTLE_TIMEOUT ))
# 4a. Wait for systemd to reach a steady state (running, or degraded when a
# benign unit like fwupd-refresh failed - both mean boot is finished).
until ssh_vm 's=$(systemctl is-system-running 2>/dev/null); [ "$s" = running ] || [ "$s" = degraded ]'; do
  [ "$(date +%s)" -ge "${settle_deadline}" ] && { log "systemd not steady after ${SETTLE_TIMEOUT}s; proceeding."; break; }
  sleep 5
done
# 4b. Stop the periodic apt/unattended-upgrades jobs and their timers for this
# run (disposable VM): they otherwise fire minutes after boot and hold the dpkg
# lock while Castellan installs packages. The shutdown-waiter daemon is left be.
ssh_vm 'sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1; true' || true
# 4c. Wait out any upgrade still holding the dpkg lock from before we stopped it.
until ! ssh_vm 'sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1'; do
  [ "$(date +%s)" -ge "${settle_deadline}" ] && { log "dpkg still locked after settle window; proceeding."; break; }
  sleep 5
done

log "VM reverted to clean-baseline and reachable as ${INIT_USER}."
