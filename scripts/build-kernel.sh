#!/bin/bash
# build-kernel.sh — Build the linux-macpro61 packages from the sibling checkout
#
# Prerequisites:
#   - Arch Linux or CachyOS build environment
#   - Dependencies declared by the authoritative PKGBUILD
#   - linux-mac checkout at LINUX_MAC_DIR (default: ../linux-mac-new)
#
# Build order after this script:
#   ./scripts/build-macfanctld.sh
#   ./scripts/build-support.sh
#   ./scripts/setup-local-repo.sh
#   ./scripts/build-iso.sh
#
# Usage:
#   ./scripts/build-kernel.sh [/path/to/linux-mac-new]
#
# Output:
#   Exactly one kernel package and matching headers package are staged in
#   local-repo/.  Current Arch uses .pkg.tar.zst; .pkg.tar.xz is also accepted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LINUX_MAC_DIR="${1:-$PROJECT_DIR/../linux-mac-new}"
LOCAL_REPO="$PROJECT_DIR/local-repo"
PACKAGING_DIR="$LINUX_MAC_DIR/packaging/arch"

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    printf 'Usage: %s [/path/to/linux-mac-new]\n' "${BASH_SOURCE[0]}"
    exit 0
fi
if (( $# > 1 )); then
    echo "ERROR: Expected at most one optional linux-mac checkout path." >&2
    exit 1
fi
if (( EUID == 0 )); then
    echo "ERROR: Do not run the kernel package build as root; run makepkg as a normal user." >&2
    exit 1
fi
if ! command -v makepkg >/dev/null 2>&1; then
    echo "ERROR: makepkg is required to build the kernel packages." >&2
    exit 1
fi
if [[ ! -d "$PACKAGING_DIR" ]]; then
    echo "ERROR: Packaging directory not found: $PACKAGING_DIR" >&2
    echo "Set the optional path to the authoritative linux-mac checkout." >&2
    exit 1
fi

# These are the local packaging inputs used by the authoritative PKGBUILD and
# by this script.  Check all of them before creating the isolated build tree.
required_inputs=(
    PKGBUILD
    config
    0001-bore.patch
)
missing_inputs=()
for input in "${required_inputs[@]}"; do
    if [[ ! -f "$PACKAGING_DIR/$input" || ! -r "$PACKAGING_DIR/$input" ]]; then
        missing_inputs+=("$PACKAGING_DIR/$input")
    fi
done
if (( ${#missing_inputs[@]} > 0 )); then
    echo "ERROR: Required linux-mac packaging input(s) are missing or unreadable:" >&2
    printf '  %s\n' "${missing_inputs[@]}" >&2
    exit 1
fi

# This validates package metadata only; it does not build or fetch the kernel.
echo ">>> Validating authoritative PKGBUILD..."
if ! (cd "$PACKAGING_DIR" && makepkg --printsrcinfo >/dev/null); then
    echo "ERROR: makepkg could not validate $PACKAGING_DIR/PKGBUILD." >&2
    echo "Check the authoritative checkout and its PKGBUILD metadata." >&2
    exit 1
fi

BUILD_DIR=""
cleanup() {
    if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
        rm -rf -- "$BUILD_DIR"
    fi
}
trap cleanup EXIT

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/linux-macpro61-build.XXXXXX")
echo "=== Building linux-macpro61 kernel packages ==="
echo "Source: $LINUX_MAC_DIR"
echo "Output: $LOCAL_REPO"
echo "Build directory: $BUILD_DIR"
echo ""

for input in "${required_inputs[@]}"; do
    cp -- "$PACKAGING_DIR/$input" "$BUILD_DIR/"
done

# Do not allow package files copied from a source checkout to be mistaken for
# output from this build.
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
echo ">>> Running makepkg with dependency and integrity checks..."
if ! makepkg --noconfirm; then
    echo "ERROR: makepkg failed." >&2
    echo "Check the dependency, source integrity, and PKGBUILD diagnostics above." >&2
    exit 1
fi

shopt -s nullglob
all_kernel_artifacts=(
    "$BUILD_DIR"/linux-macpro61-*-x86_64.pkg.tar.zst
    "$BUILD_DIR"/linux-macpro61-*-x86_64.pkg.tar.xz
)
shopt -u nullglob

kernel_artifacts=()
header_artifacts=()
for artifact in "${all_kernel_artifacts[@]}"; do
    artifact_name=${artifact##*/}
    if [[ $artifact_name == linux-macpro61-headers-* ]]; then
        header_artifacts+=("$artifact")
    else
        kernel_artifacts+=("$artifact")
    fi
done

if (( ${#kernel_artifacts[@]} != 1 )); then
    echo "ERROR: Expected exactly one x86_64 linux-macpro61 package; found ${#kernel_artifacts[@]}." >&2
    printf '  %s\n' "${kernel_artifacts[@]:-none}" >&2
    exit 1
fi
if (( ${#header_artifacts[@]} != 1 )); then
    echo "ERROR: Expected exactly one x86_64 linux-macpro61-headers package; found ${#header_artifacts[@]}." >&2
    printf '  %s\n' "${header_artifacts[@]:-none}" >&2
    exit 1
fi

kernel_name=${kernel_artifacts[0]##*/}
kernel_name=${kernel_name%.pkg.tar.zst}
kernel_name=${kernel_name%.pkg.tar.xz}
kernel_key=${kernel_name#linux-macpro61-}
matching_headers=()
for header in "${header_artifacts[@]}"; do
    header_name=${header##*/}
    header_name=${header_name%.pkg.tar.zst}
    header_name=${header_name%.pkg.tar.xz}
    if [[ ${header_name#linux-macpro61-headers-} == "$kernel_key" ]]; then
        matching_headers+=("$header")
    fi
done
if (( ${#matching_headers[@]} != 1 )); then
    echo "ERROR: Expected exactly one headers package matching $kernel_name; found ${#matching_headers[@]}." >&2
    printf '  %s\n' "${matching_headers[@]:-none}" >&2
    exit 1
fi

mkdir -p "$LOCAL_REPO"

# Invalidate repository metadata, then replace only prior kernel/header package
# artifacts.  In particular, do not remove macfanctld packages here.
rm -f "$LOCAL_REPO"/macpro.db* "$LOCAL_REPO/macpro.manifest"
shopt -s nullglob
old_kernel_headers=(
    "$LOCAL_REPO"/linux-macpro61-*.pkg.tar.zst
    "$LOCAL_REPO"/linux-macpro61-*.pkg.tar.xz
)
shopt -u nullglob
for old_artifact in "${old_kernel_headers[@]}"; do
    rm -f -- "$old_artifact" "$old_artifact.sig"
done

echo ">>> Staging kernel and headers..."
cp -- "${kernel_artifacts[0]}" "$LOCAL_REPO/"
cp -- "${matching_headers[0]}" "$LOCAL_REPO/"

echo ""
echo "=== Kernel build complete ==="
echo "Kernel: ${kernel_artifacts[0]##*/}"
echo "Headers: ${matching_headers[0]##*/}"
echo "Output: $LOCAL_REPO"
echo ""
echo "Next steps: build macfanctld and macpro61-support, then run scripts/setup-local-repo.sh"
