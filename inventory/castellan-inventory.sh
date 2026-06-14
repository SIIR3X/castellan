#!/usr/bin/env bash
#
# Castellan dynamic inventory.
#
# Every inventory/host_vars/<host>.yml is automatically exposed as a host in the
# 'vps' group. Create a per-host config (./harden init <host>) and the host
# appears here - you never edit a static inventory file by hand. Per-host vars
# and group_vars/all.yml are still loaded by Ansible from the adjacent
# host_vars/ and group_vars/ directories.
set -euo pipefail

HV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host_vars"

emit_list() {
  local out="" first=1 f b
  if [ -d "$HV" ]; then
    for f in "$HV"/*.yml; do
      [ -e "$f" ] || continue
      b="$(basename "$f" .yml)"
      if [ "$first" -eq 1 ]; then out="\"$b\""; first=0; else out="${out}, \"$b\""; fi
    done
  fi
  printf '{"vps": {"hosts": [%s]}, "_meta": {"hostvars": {}}}\n' "$out"
}

case "${1:---list}" in
  --host) printf '{}\n' ;;
  *)      emit_list ;;
esac
