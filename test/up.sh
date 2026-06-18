#!/usr/bin/env bash
#
# Bring up the disposable Castellan test target (Approach A: podman + sshd).
# Generates a throwaway SSH key if needed, builds the image and runs the
# container on 127.0.0.1:2222 (root, key-only). Idempotent: re-run to reset.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${HERE}/secrets/id_test"
IMAGE="castellan-sshd"
NAME="castellan-target"
PORT=2222

command -v podman >/dev/null 2>&1 || {
  echo "[x] podman not found. Install it first:" >&2
  echo "    sudo apt-get update && sudo apt-get install -y podman" >&2
  exit 1
}

mkdir -p "${HERE}/secrets"
if [ ! -f "${KEY}" ]; then
  echo "[*] Generating disposable test key: ${KEY}"
  ssh-keygen -t ed25519 -N '' -f "${KEY}" -C castellan-test >/dev/null
fi

echo "[*] Building image ${IMAGE}"
podman build -t "${IMAGE}" -f "${HERE}/Containerfile" "${HERE}"

echo "[*] (Re)starting container ${NAME} on 127.0.0.1:${PORT}"
podman rm -f "${NAME}" >/dev/null 2>&1 || true
podman run -d --name "${NAME}" -p "127.0.0.1:${PORT}:22" "${IMAGE}" >/dev/null

# Drop any stale host key for the loopback test endpoint.
ssh-keygen -R "[127.0.0.1]:${PORT}" >/dev/null 2>&1 || true

echo "[+] Target up. Sanity check:"
ssh -p "${PORT}" -i "${KEY}" -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null root@127.0.0.1 'echo "    sshd OK as $(id -un)"'
echo "[+] Now run:  ./test/run.sh audit   then   ./test/run.sh apply"
