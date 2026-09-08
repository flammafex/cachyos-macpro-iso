#!/bin/bash
# build-support.sh — Build and stage the macpro61-support package

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_DIR/packages/macpro61-support"
LOCAL_REPO="$PROJECT_DIR/local-repo"

if [[ ${1:-} == '-h' || ${1:-} == '--help' ]]; then
    printf 'Usage: %s\n' "${BASH_SOURCE[0]}"
    exit 0
fi
if (( $# != 0 )); then
    echo 'ERROR: This script takes no arguments.' >&2
    exit 1
fi
if (( EUID == 0 )); then
    echo 'ERROR: Do not run this package build as root; run makepkg as a normal user.' >&2
    exit 1
fi
command -v makepkg >/dev/null 2>&1 || { echo 'ERROR: makepkg is required.' >&2; exit 1; }
[[ -f "$SOURCE_DIR/PKGBUILD" ]] || { echo "ERROR: PKGBUILD not found: $SOURCE_DIR/PKGBUILD" >&2; exit 1; }

echo ">>> Validating $SOURCE_DIR/PKGBUILD"
(cd "$SOURCE_DIR" && makepkg --printsrcinfo >/dev/null)

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/macpro61-support-build.XXXXXX")
trap 'rm -rf -- "$BUILD_DIR"' EXIT
cp -a "$SOURCE_DIR"/. "$BUILD_DIR"/

shopt -s nullglob
stale_artifacts=(
    "$BUILD_DIR"/*.pkg.tar.zst
    "$BUILD_DIR"/*.pkg.tar.xz
    "$BUILD_DIR"/*.pkg.tar.zst.sig
    "$BUILD_DIR"/*.pkg.tar.xz.sig
)
shopt -u nullglob
(( ${#stale_artifacts[@]} == 0 )) || rm -f -- "${stale_artifacts[@]}"

echo '>>> Building macpro61-support'
(cd "$BUILD_DIR" && makepkg --noconfirm)

shopt -s nullglob
artifacts=(
    "$BUILD_DIR"/macpro61-support-*-x86_64.pkg.tar.zst
    "$BUILD_DIR"/macpro61-support-*-x86_64.pkg.tar.xz
)
shopt -u nullglob
if (( ${#artifacts[@]} != 1 )); then
    echo "ERROR: Expected exactly one macpro61-support artifact; found ${#artifacts[@]}." >&2
    printf '  %s\n' "${artifacts[@]:-none}" >&2
    exit 1
fi

mkdir -p "$LOCAL_REPO"
rm -f "$LOCAL_REPO"/macpro.db* "$LOCAL_REPO/macpro.manifest"
shopt -s nullglob
old_artifacts=(
    "$LOCAL_REPO"/macpro61-support-*.pkg.tar.zst
    "$LOCAL_REPO"/macpro61-support-*.pkg.tar.xz
)
shopt -u nullglob
for old_artifact in "${old_artifacts[@]}"; do
    rm -f -- "$old_artifact" "$old_artifact.sig"
done
cp -- "${artifacts[0]}" "$LOCAL_REPO/"

echo "=== macpro61-support staged in $LOCAL_REPO ==="
echo "Package: $LOCAL_REPO/${artifacts[0]##*/}"
echo 'Run scripts/setup-local-repo.sh before building the ISO.'
