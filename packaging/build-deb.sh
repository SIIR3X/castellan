#!/usr/bin/env bash
#
# Build a Castellan .deb (architecture: all) with plain dpkg-deb - no debhelper
# required. Usage: packaging/build-deb.sh [version] [output-dir]
# Version defaults to `git describe` (leading 'v' stripped); output-dir to dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
OUTDIR="${2:-${ROOT}/dist}"

if [ -z "$VERSION" ]; then
  VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0)"
fi
VERSION="${VERSION#v}"                      # strip a leading v (v1.2.3 -> 1.2.3)

PKG="castellan"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
SHARE="${STAGE}/usr/share/castellan"
DOC="${STAGE}/usr/share/doc/castellan"
MAN="${STAGE}/usr/share/man/man1"

echo "[*] Building ${PKG} ${VERSION}"

mkdir -p "${STAGE}/DEBIAN" "${SHARE}" "${STAGE}/usr/bin" "${DOC}" "${MAN}"

# --- program files (immutable) ----------------------------------------------
cp -a "${ROOT}/harden" "${ROOT}/ansible.cfg" "${SHARE}/"
cp -a "${ROOT}/playbooks" "${ROOT}/roles" "${ROOT}/lib" "${SHARE}/"
mkdir -p "${SHARE}/inventory/group_vars"
cp -a "${ROOT}/inventory/group_vars/." "${SHARE}/inventory/group_vars/"
cp -a "${ROOT}/inventory/castellan-inventory.sh" "${SHARE}/inventory/"
cp -a "${ROOT}/inventory/host_vars.example.yml" "${SHARE}/inventory/" 2>/dev/null || true

# never ship a developer's host configs or reports
rm -rf "${SHARE}/inventory/host_vars" "${SHARE}/reports" "${SHARE}/test"

chmod 0755 "${SHARE}/harden" "${SHARE}/inventory/castellan-inventory.sh"
ln -s /usr/share/castellan/harden "${STAGE}/usr/bin/castellan"

# --- docs + man --------------------------------------------------------------
cp -a "${ROOT}/README.md" "${DOC}/" 2>/dev/null || true
cp -a "${ROOT}/LICENSE" "${DOC}/copyright"
gzip -9 -n -c "${ROOT}/packaging/castellan.1" > "${MAN}/castellan.1.gz"

# --- control -----------------------------------------------------------------
sed "s/@VERSION@/${VERSION}/" "${ROOT}/packaging/control.in" > "${STAGE}/DEBIAN/control"

# --- build -------------------------------------------------------------------
mkdir -p "${OUTDIR}"
DEB="${OUTDIR}/${PKG}_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "${STAGE}" "${DEB}" >/dev/null

echo "[+] Built ${DEB}"
dpkg-deb --info "${DEB}" | sed -n '1,3p;/Depends/p;/Description/p'
