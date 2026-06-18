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

# Installed mode points here at the per-user host_vars dir; source mode falls
# back to the host_vars/ next to this script.
HV="${CASTELLAN_HOST_VARS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host_vars}"

emit_list() {
  local out="" meta="" first=1 f b ip
  if [ -d "$HV" ]; then
    for f in "$HV"/*.yml; do
      [ -e "$f" ] || continue
      b="$(basename "$f" .yml)"
      if [ "$first" -eq 1 ]; then out="\"$b\""; first=0; else out="${out}, \"$b\""; fi
      # Map target_ip -> ansible_host so the connection address is the IP/FQDN
      # from host_vars, not the inventory name (which need not resolve).
      ip="$(sed -n 's/^target_ip:[[:space:]]*//p' "$f" | head -n1 | tr -d '[:space:]\r')"
      if [ -n "$ip" ]; then
        [ -n "$meta" ] && meta="${meta}, "
        meta="${meta}\"$b\": {\"ansible_host\": \"$ip\"}"
      fi
    done
  fi
  printf '{"vps": {"hosts": [%s]}, "_meta": {"hostvars": {%s}}}\n' "$out" "$meta"
}

case "${1:---list}" in
  --host) printf '{}\n' ;;
  *)      emit_list ;;
esac
