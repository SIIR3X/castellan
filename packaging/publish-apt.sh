#!/usr/bin/env bash
#
# Refresh a flat, signed apt repository (served by GitHub Pages).
# Usage: packaging/publish-apt.sh <repo-dir> <deb> [<deb> ...]
#
# Adds the given .deb(s) to <repo-dir>/pool, regenerates Packages + Release over
# the WHOLE pool, signs Release (InRelease + Release.gpg) and exports the public
# key. Run it against a checkout of the gh-pages branch so old versions persist.
#
# Env:
#   GPG_KEY_ID       signing identity (fingerprint or email)   [required]
#   GPG_PASSPHRASE   key passphrase                            [optional]
#   REPO_ORIGIN/REPO_LABEL/REPO_SUITE  Release metadata        [optional]
set -euo pipefail

REPO="${1:?usage: publish-apt.sh <repo-dir> <deb>...}"; shift
: "${GPG_KEY_ID:?set GPG_KEY_ID to the signing key id}"
ORIGIN="${REPO_ORIGIN:-Castellan}"
LABEL="${REPO_LABEL:-Castellan}"
SUITE="${REPO_SUITE:-stable}"

mkdir -p "${REPO}/pool"
for d in "$@"; do
  [ -f "$d" ] || { echo "no such .deb: $d" >&2; exit 1; }
  cp -f "$d" "${REPO}/pool/"
done

cd "$REPO"
rm -f Release InRelease Release.gpg

apt-ftparchive packages pool > Packages
gzip -9 -kf Packages
apt-ftparchive \
  -o "APT::FTPArchive::Release::Origin=${ORIGIN}" \
  -o "APT::FTPArchive::Release::Label=${LABEL}" \
  -o "APT::FTPArchive::Release::Suite=${SUITE}" \
  -o "APT::FTPArchive::Release::Codename=${SUITE}" \
  -o "APT::FTPArchive::Release::Architectures=all" \
  -o "APT::FTPArchive::Release::Components=main" \
  release . > Release

GPG=(gpg --batch --yes --default-key "${GPG_KEY_ID}")
if [ -n "${GPG_PASSPHRASE:-}" ]; then
  GPG+=(--pinentry-mode loopback --passphrase "${GPG_PASSPHRASE}")
fi
"${GPG[@]}" --clearsign -o InRelease Release
"${GPG[@]}" -abs -o Release.gpg Release

# Public key for the client's signed-by= line.
gpg --export "${GPG_KEY_ID}" > castellan-archive-keyring.gpg
gpg --armor --export "${GPG_KEY_ID}" > castellan-archive-keyring.asc

echo "[+] apt repository refreshed in ${REPO}"
ls -1 pool   # already inside "${REPO}" after the cd above
