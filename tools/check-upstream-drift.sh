#!/usr/bin/env bash
#
# check-upstream-drift.sh — diff the live community-scripts Immich scripts against
# the snapshots in vendor/.
#
# ct/gallery.sh and lib/*.func carry copies of upstream logic (the Debian testing
# repo setup, the OpenVINO refresh, the image-library recompiles, the whole build
# sequence). When upstream changes any of it, those copies need the same change.
# Run this before bumping the pinned Gallery release.
#
#   tools/check-upstream-drift.sh            # show the diff, exit 1 if drifted
#   tools/check-upstream-drift.sh --update   # accept upstream as the new snapshot

set -euo pipefail

UPSTREAM_REPO="community-scripts/ProxmoxVE"
RAW="https://raw.githubusercontent.com/${UPSTREAM_REPO}/main"
API="https://api.github.com/repos/${UPSTREAM_REPO}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"

# upstream path -> vendor filename
FILES=(
  "ct/immich.sh:ct-immich.sh"
  "install/immich-install.sh:immich-install.sh"
)

update=0
[[ "${1:-}" == "--update" ]] && update=1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

drifted=0

for entry in "${FILES[@]}"; do
  upstream_path="${entry%%:*}"
  vendor_name="${entry##*:}"
  vendor_file="${VENDOR_DIR}/${vendor_name}"

  curl -fsSL "${RAW}/${upstream_path}" -o "${tmp}/${vendor_name}"

  if [[ ! -f "$vendor_file" ]]; then
    echo "!! no snapshot for ${upstream_path}"
    drifted=1
    [[ "$update" -eq 1 ]] && cp "${tmp}/${vendor_name}" "$vendor_file"
    continue
  fi

  if diff -q "$vendor_file" "${tmp}/${vendor_name}" >/dev/null; then
    echo "ok   ${upstream_path} — unchanged"
    continue
  fi

  drifted=1
  echo ""
  echo "DRIFT ${upstream_path}"
  echo "-----------------------------------------------------------------------"
  diff -u "$vendor_file" "${tmp}/${vendor_name}" || true
  echo "-----------------------------------------------------------------------"

  if [[ "$update" -eq 1 ]]; then
    cp "${tmp}/${vendor_name}" "$vendor_file"
    echo "     snapshot updated"
  fi
done

if [[ "$drifted" -eq 1 ]]; then
  echo ""
  echo "Upstream changed. Check whether any of it needs porting into:"
  echo "  lib/build.func         (build sequence, path fixups, ML sync)"
  echo "  lib/compile-libs.func  (pinned library revisions)"
  echo "  ct/gallery.sh          (apt/mise/OpenVINO/VectorChord maintenance blocks)"
  echo ""
  latest_sha="$(curl -fsSL "${API}/commits?path=ct/immich.sh&per_page=1" | grep -m1 '"sha"' | cut -d'"' -f4)"
  echo "Current upstream commit for ct/immich.sh: ${latest_sha}"
  echo "Record it in vendor/VENDOR.md and in the SYNCED-FROM headers once ported."
  [[ "$update" -eq 1 ]] && exit 0
  exit 1
fi

echo ""
echo "No drift."
