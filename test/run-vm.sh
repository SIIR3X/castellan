#!/usr/bin/env bash
#
# Run Castellan against the disposable Hyper-V VM via the real ./harden wrapper,
# with the VM test inventory (so the tracked inventory/hosts.yml is untouched).
#
# Usage: ./test/run-vm.sh audit|apply [extra ansible-playbook args...]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
MODE="${1:-audit}"; shift || true

case "${MODE}" in
  audit|apply) ;;
  *) echo "Usage: $0 audit|apply [args...]" >&2; exit 1 ;;
esac

cd "${ROOT}"
ANSIBLE_INVENTORY="test/inventory.vm.yml" ./harden "${MODE}" 192.168.1.43 "$@"
