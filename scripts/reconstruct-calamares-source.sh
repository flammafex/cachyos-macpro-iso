#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE_DIR="${CALAMARES_SOURCE_DIR:-$PROJECT_DIR/../cachyos-calamares-next}"

UPSTREAM_REPO="https://github.com/CachyOS/CachyOS-PKGBUILDS.git"
UPSTREAM_COMMIT="8b4efe0e7d8191db4ef02d9fb864e86aad32e93e"
UPSTREAM_SUBDIR="cachyos-calamares"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 ||
    fail "git is required"

if [[ -e "$SOURCE_DIR" ]]; then
    if [[ -f "$SOURCE_DIR/PKGBUILD" ]] &&
       grep -qx 'pkgname=cachyos-calamares-next' "$SOURCE_DIR/PKGBUILD" &&
       grep -qx 'pkgver=3.4.2' "$SOURCE_DIR/PKGBUILD" &&
       grep -qx 'pkgrel=13.1' "$SOURCE_DIR/PKGBUILD"; then
        echo "Calamares source already reconstructed:"
        echo "  $SOURCE_DIR"
        exit 0
    fi

    fail "refusing to overwrite existing path: $SOURCE_DIR"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/cachyos-calamares-source.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

echo ">>> Fetching CachyOS Calamares packaging source..."

git clone \
    --filter=blob:none \
    --no-checkout \
    "$UPSTREAM_REPO" \
    "$tmp/CachyOS-PKGBUILDS"

git -C "$tmp/CachyOS-PKGBUILDS" sparse-checkout init --cone
git -C "$tmp/CachyOS-PKGBUILDS" sparse-checkout set "$UPSTREAM_SUBDIR"
git -C "$tmp/CachyOS-PKGBUILDS" checkout "$UPSTREAM_COMMIT"

mkdir -p "$(dirname "$SOURCE_DIR")"
cp -a \
    "$tmp/CachyOS-PKGBUILDS/$UPSTREAM_SUBDIR" \
    "$SOURCE_DIR"

grep -qx 'pkgrel=13' "$SOURCE_DIR/PKGBUILD" ||
    fail "unexpected upstream pkgrel"

sed -i \
    's/^pkgrel=13$/pkgrel=13.1/' \
    "$SOURCE_DIR/PKGBUILD"

if [[ -f "$SOURCE_DIR/.SRCINFO" ]]; then
    sed -i \
        's/^\tpkgrel = 13$/\tpkgrel = 13.1/' \
        "$SOURCE_DIR/.SRCINFO"
fi

grep -qx 'pkgrel=13.1' "$SOURCE_DIR/PKGBUILD" ||
    fail "failed to apply local pkgrel"

echo ">>> Reconstructed:"
echo "    $SOURCE_DIR"
echo
echo "Local modification:"
echo "    pkgrel 13 -> 13.1"
echo
echo "Now run:"
echo "    ./scripts/build-calamares.sh"
