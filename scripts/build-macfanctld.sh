#!/bin/bash
# build-macfanctld.sh — Build and stage the authoritative macfanctld package
#
# Usage:
#   MACFANCTLD_SOURCE_DIR=/path/to/macfanctld-new ./scripts/build-macfanctld.sh
#
# MACFANCTLD_SOURCE_DIR defaults to ../macfanctld-new relative to this project.
# Run scripts/build-support.sh next, then scripts/setup-local-repo.sh and
# scripts/build-iso.sh.
# The source PKGBUILD is copied to an isolated temporary build directory, so
# stale package files in the source tree cannot be mistaken for build output.
# This script deliberately does not request dependency synchronization: it
# never installs packages on the host and must be run as a non-root user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="${MACFANCTLD_SOURCE_DIR:-$PROJECT_DIR/../macfanctld-new}"
LOCAL_REPO="$PROJECT_DIR/local-repo"

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    printf 'Usage: MACFANCTLD_SOURCE_DIR=/path/to/macfanctld-new %s\n' "${BASH_SOURCE[0]}"
    exit 0
fi
if (( $# != 0 )); then
    echo "ERROR: This script takes no arguments; set MACFANCTLD_SOURCE_DIR instead." >&2
    exit 1
fi

if (( EUID == 0 )); then
    echo "ERROR: Do not run this package build as root; run makepkg as a normal user." >&2
    exit 1
fi
if ! command -v makepkg >/dev/null 2>&1; then
    echo "ERROR: makepkg is required to build macfanctld." >&2
    exit 1
fi
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: macfanctld source directory not found: $SOURCE_DIR" >&2
    exit 1
fi
if [[ ! -f "$SOURCE_DIR/PKGBUILD" ]]; then
    echo "ERROR: PKGBUILD not found in authoritative source: $SOURCE_DIR" >&2
    exit 1
fi

# This parses package metadata only; it does not run the package build.
echo ">>> Validating source PKGBUILD: $SOURCE_DIR/PKGBUILD"
if ! (cd "$SOURCE_DIR" && makepkg --printsrcinfo >/dev/null); then
    echo "ERROR: Invalid macfanctld PKGBUILD: $SOURCE_DIR/PKGBUILD" >&2
    exit 1
fi

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/macfanctld-build.XXXXXX")
trap 'rm -rf -- "$BUILD_DIR"' EXIT

echo "=== Building authoritative macfanctld package ==="
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
    echo "ERROR: Expected exactly one x86_64 package artifact from macfanctld; found ${#resulting_artifacts[@]}." >&2
    printf '  %s\n' "${resulting_artifacts[@]:-none}" >&2
    exit 1
fi

artifact=${resulting_artifacts[0]}
artifact_name=${artifact##*/}
if [[ $artifact_name != macfanctld-*.pkg.tar.zst && $artifact_name != macfanctld-*.pkg.tar.xz ]]; then
    echo "ERROR: Build produced an unexpected x86_64 package: $artifact_name" >&2
    exit 1
fi

mkdir -p "$LOCAL_REPO"
rm -f "$LOCAL_REPO"/macpro.db* "$LOCAL_REPO/macpro.manifest"
shopt -s nullglob
old_macfan_packages=(
    "$LOCAL_REPO"/macfanctld-*.pkg.tar.zst
    "$LOCAL_REPO"/macfanctld-*.pkg.tar.xz
)
shopt -u nullglob
for old_package in "${old_macfan_packages[@]}"; do
    rm -f -- "$old_package" "$old_package.sig"
done
cp -- "$artifact" "$LOCAL_REPO/"

echo "=== macfanctld package staged ==="
echo "Package: $LOCAL_REPO/$artifact_name"
echo "Run scripts/build-support.sh, then scripts/setup-local-repo.sh before building the ISO."
