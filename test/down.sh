#!/usr/bin/env bash
#
# Tear down the disposable Castellan test target.
set -euo pipefail
podman rm -f castellan-target >/dev/null 2>&1 && echo "[+] Container removed." \
  || echo "[*] No running container."
