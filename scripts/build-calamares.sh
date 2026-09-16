#!/bin/bash
# build-calamares.sh — Build and stage the authoritative cachyos-calamares-next package
#
# Usage:
#   CALAMARES_SOURCE_DIR=/path/to/cachyos-calamares-next ./scripts/build-calamares.sh
#
# CALAMARES_SOURCE_DIR defaults to ../cachyos-calamares-next relative to this project.
# Run scripts/setup-local-repo.sh and scripts/build-iso.sh next.
# The source PKGBUILD is copied to an isolated temporary build directory, so
# stale package files in the source tree cannot be mistaken for build output.
# This script deliberately does not request dependency synchronization: it
# never installs packages on the host and must be run as a non-root user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="${CALAMARES_SOURCE_DIR:-$PROJECT_DIR/../cachyos-calamares-next}"
LOCAL_REPO="$PROJECT_DIR/local-repo"

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    printf 'Usage: CALAMARES_SOURCE_DIR=/path/to/cachyos-calamares-next %s\n' "${BASH_SOURCE[0]}"
    exit 0
fi
if (( $# != 0 )); then
    echo "ERROR: This script takes no arguments; set CALAMARES_SOURCE_DIR instead." >&2
    exit 1
fi

if (( EUID == 0 )); then
    echo "ERROR: Do not run this package build as root; run makepkg as a normal user." >&2
    exit 1
fi
if ! command -v makepkg >/dev/null 2>&1; then
    echo "ERROR: makepkg is required to build cachyos-calamares-next." >&2
    exit 1
fi
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: cachyos-calamares-next source directory not found: $SOURCE_DIR" >&2
    exit 1
fi
if [[ ! -f "$SOURCE_DIR/PKGBUILD" ]]; then
    echo "ERROR: PKGBUILD not found in authoritative source: $SOURCE_DIR" >&2
    exit 1
fi

# This parses package metadata only; it does not run the package build.
echo ">>> Validating source PKGBUILD: $SOURCE_DIR/PKGBUILD"
if ! (cd "$SOURCE_DIR" && makepkg --printsrcinfo >/dev/null); then
    echo "ERROR: Invalid cachyos-calamares-next PKGBUILD: $SOURCE_DIR/PKGBUILD" >&2
    exit 1
fi

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/calamares-build.XXXXXX")
trap 'rm -rf -- "$BUILD_DIR"' EXIT

echo "=== Building authoritative cachyos-calamares-next package ==="
echo "Source: $SOURCE_DIR"
echo "Output: $LOCAL_REPO"
echo "Build directory: $BUILD_DIR"

# Copy the complete source tree because PKGBUILD files commonly refer to local
# sources, patches, or a repository checkout.  The temporary directory starts
# with no package artifacts, making the post-build result unambiguous.
cp -a "$SOURCE_DIR"/. "$BUILD_DIR"/
shopt -s nullglob
stale_artifacts=(
    "$BUILD_DIR"/*.pkg.tar.zst
    "$BUILD_DIR"/*.pkg.tar.xz
    "$BUILD_DIR"/*.pkg.tar.zst.sig
    "$BUILD_DIR"/*.pkg.tar.xz.sig
)
shopt -u nullglob
if (( ${#stale_artifacts[@]} > 0 )); then
    rm -f -- "${stale_artifacts[@]}"
fi

cd "$BUILD_DIR"
echo ">>> Running makepkg (without dependency installation) ..."
makepkg --noconfirm

shopt -s nullglob
resulting_artifacts=(
    "$BUILD_DIR"/*-x86_64.pkg.tar.zst
    "$BUILD_DIR"/*-x86_64.pkg.tar.xz
)
shopt -u nullglob

if (( ${#resulting_artifacts[@]} != 1 )); then
    echo "ERROR: Expected exactly one x86_64 package artifact from cachyos-calamares-next; found ${#resulting_artifacts[@]}." >&2
    printf '  %s\n' "${resulting_artifacts[@]:-none}" >&2
    exit 1
fi

artifact=${resulting_artifacts[0]}
artifact_name=${artifact##*/}
if [[ $artifact_name != cachyos-calamares-next-*.pkg.tar.zst && $artifact_name != cachyos-calamares-next-*.pkg.tar.xz ]]; then
    echo "ERROR: Build produced an unexpected x86_64 package: $artifact_name" >&2
    exit 1
fi

mkdir -p "$LOCAL_REPO"
rm -f "$LOCAL_REPO"/macpro.db* "$LOCAL_REPO/macpro.manifest"
shopt -s nullglob
old_calamares_packages=(
    "$LOCAL_REPO"/cachyos-calamares-next-*.pkg.tar.zst
    "$LOCAL_REPO"/cachyos-calamares-next-*.pkg.tar.xz
)
shopt -u nullglob
for old_package in "${old_calamares_packages[@]}"; do
    rm -f -- "$old_package" "$old_package.sig"
done
cp -- "$artifact" "$LOCAL_REPO/"

echo "=== cachyos-calamares-next package staged ==="
echo "Package: $LOCAL_REPO/$artifact_name"
echo "Run scripts/setup-local-repo.sh before building the ISO."
