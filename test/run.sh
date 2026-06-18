#!/usr/bin/env bash
#
# Run Castellan against the disposable test target via the real ./harden
# wrapper, but with the test inventory (ANSIBLE_INVENTORY override) so the
# tracked inventory/hosts.yml is never touched.
#
# Usage: ./test/run.sh audit|apply [extra ansible-playbook args...]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
MODE="${1:-audit}"; shift || true

case "${MODE}" in
  audit|apply) ;;
  *) echo "Usage: $0 audit|apply [args...]" >&2; exit 1 ;;
esac

cd "${ROOT}"
ANSIBLE_INVENTORY="test/inventory.yml" ./harden "${MODE}" 127.0.0.1 "$@"
