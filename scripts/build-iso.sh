#!/bin/bash
# build-iso.sh — Build the CachyOS Mac Pro 6,1 ISO
#
# Prerequisites:
#   - Arch Linux or CachyOS build environment
#   - Kernel, macfanctld, and macpro61-support packages built
#   - local-repo/ set up with ./scripts/setup-local-repo.sh
#   - archiso, mkinitcpio-archiso, squashfs-tools, grub installed
#
# Usage:
#   ./scripts/build-iso.sh [-c] [-v]
#     -c    Clean build directory first
#     -v    Verbose output
#
# Build order:
#   ./scripts/build-support.sh
#   ./scripts/setup-local-repo.sh
#   ./scripts/build-iso.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_REPO="$PROJECT_DIR/local-repo"
MANIFEST="$LOCAL_REPO/macpro.manifest"
MANIFEST_TMP=""

cleanup_manifest() {
    if [[ -n "$MANIFEST_TMP" ]]; then
        rm -f -- "$MANIFEST_TMP"
    fi
}
trap cleanup_manifest EXIT

CLEAN=false
VERBOSE=false

while getopts "cvh" opt; do
    case $opt in
        c) CLEAN=true ;;
        v) VERBOSE=true ;;
        h) echo "Usage: $0 [-c] [-v]"; exit 0 ;;
        *) echo "Unknown option: -$opt"; exit 1 ;;
    esac
done

# Verify local-repo has the exact package set needed by the ISO.
if [[ ! -f "$LOCAL_REPO/macpro.db" || ! -f "$LOCAL_REPO/macpro.db.tar.gz" ]]; then
    echo "ERROR: Local repo not set up. Run scripts/setup-local-repo.sh first."
    exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Local repo manifest missing: $MANIFEST" >&2
    echo "Run scripts/setup-local-repo.sh first." >&2
    exit 1
fi
if ! command -v pacman >/dev/null 2>&1; then
    echo "ERROR: pacman is required to validate local package metadata." >&2
    exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    echo "ERROR: sha256sum is required to verify the local repo manifest." >&2
    exit 1
fi

shopt -s nullglob
package_files=(
    "$LOCAL_REPO"/*.pkg.tar.zst
    "$LOCAL_REPO"/*.pkg.tar.xz
)
shopt -u nullglob

if (( ${#package_files[@]} != 4 )); then
    echo "ERROR: Expected exactly four package artifacts in local-repo/; found ${#package_files[@]}." >&2
    printf '  %s\n' "${package_files[@]:-none}" >&2
    exit 1
fi

read_package_metadata() {
    local artifact="$1" metadata line value

    if ! metadata=$(LC_ALL=C pacman -Qp --info "$artifact" 2>/dev/null); then
        echo "ERROR: Cannot read pacman metadata from $artifact" >&2
        exit 1
    fi

    PACKAGE_NAME=""
    PACKAGE_VERSION=""
    PACKAGE_ARCH=""
    while IFS= read -r line; do
        case "$line" in
            Name*:*) value=${line#*:}; PACKAGE_NAME="${value#"${value%%[![:space:]]*}"}" ;;
            Version*:*) value=${line#*:}; PACKAGE_VERSION="${value#"${value%%[![:space:]]*}"}" ;;
            Architecture*:*) value=${line#*:}; PACKAGE_ARCH="${value#"${value%%[![:space:]]*}"}" ;;
        esac
    done <<< "$metadata"
    if [[ -z ${PACKAGE_NAME:-} || -z ${PACKAGE_VERSION:-} || -z ${PACKAGE_ARCH:-} ]]; then
        echo "ERROR: Incomplete pacman metadata in $artifact" >&2
        exit 1
    fi
}

kernel_package=""
headers_package=""
macfan_package=""
support_package=""
kernel_version=""
headers_version=""
macfan_version=""
support_version=""
for artifact in "${package_files[@]}"; do
    read_package_metadata "$artifact"
    artifact_name=${artifact##*/}
    case "$artifact_name" in
        "${PACKAGE_NAME}-${PACKAGE_VERSION}-${PACKAGE_ARCH}.pkg.tar.zst"|"${PACKAGE_NAME}-${PACKAGE_VERSION}-${PACKAGE_ARCH}.pkg.tar.xz") ;;
        *)
            echo "ERROR: Package filename does not match metadata: $artifact_name" >&2
            exit 1
            ;;
    esac
    if [[ $PACKAGE_ARCH != x86_64 ]]; then
        echo "ERROR: Package $artifact has architecture $PACKAGE_ARCH, expected x86_64." >&2
        exit 1
    fi
    case "$PACKAGE_NAME" in
        linux-macpro61)
            [[ -z $kernel_package ]] || { echo "ERROR: Duplicate linux-macpro61 package." >&2; exit 1; }
            kernel_package="$artifact"
            kernel_version="$PACKAGE_VERSION"
            ;;
        linux-macpro61-headers)
            [[ -z $headers_package ]] || { echo "ERROR: Duplicate linux-macpro61-headers package." >&2; exit 1; }
            headers_package="$artifact"
            headers_version="$PACKAGE_VERSION"
            ;;
        macfanctld)
            [[ -z $macfan_package ]] || { echo "ERROR: Duplicate macfanctld package." >&2; exit 1; }
            macfan_package="$artifact"
            macfan_version="$PACKAGE_VERSION"
            ;;
        macpro61-support)
            [[ -z $support_package ]] || { echo "ERROR: Duplicate macpro61-support package." >&2; exit 1; }
            support_package="$artifact"
            support_version="$PACKAGE_VERSION"
            ;;
        *)
            echo "ERROR: Unexpected package name $PACKAGE_NAME in $artifact." >&2
            exit 1
            ;;
    esac
done

if [[ -z $kernel_package || -z $headers_package || -z $macfan_package || -z $support_package ]]; then
    echo "ERROR: Package set must contain linux-macpro61, matching headers, macfanctld, and macpro61-support." >&2
    exit 1
fi
if [[ $kernel_version != "$headers_version" ]]; then
    echo "ERROR: Kernel version $kernel_version does not match headers version $headers_version." >&2
    exit 1
fi

manifest_files=(
    macpro.db
    macpro.db.tar.gz
    "${kernel_package##*/}"
    "${headers_package##*/}"
    "${macfan_package##*/}"
    "${support_package##*/}"
)
MANIFEST_TMP=$(mktemp)
(
    cd "$LOCAL_REPO"
    sha256sum -- "${manifest_files[@]}"
) | LC_ALL=C sort -k2,2 > "$MANIFEST_TMP"
if ! (cd "$LOCAL_REPO" && sha256sum -c -- "$MANIFEST" >/dev/null); then
    echo "ERROR: Local repo manifest checksum verification failed." >&2
    exit 1
fi
if ! cmp -s "$MANIFEST_TMP" "$MANIFEST"; then
    echo "ERROR: Local repo manifest does not cover the validated package quartet and DB." >&2
    exit 1
fi

echo "Preflight packages:"
echo "  Kernel: ${kernel_package##*/}"
echo "  Headers: ${headers_package##*/}"
echo "  Fan daemon: ${macfan_package##*/}"
echo "  Fan daemon version: $macfan_version"
echo "  Support: ${support_package##*/} (version $support_version)"

echo "=== Building CachyOS Mac Pro 6,1 ISO ==="
echo "Local repo: $LOCAL_REPO"
echo ""

# Build
cd "$PROJECT_DIR"

BUILD_CMD=(sudo ./buildiso.sh -p desktop -w)
if $VERBOSE; then
    BUILD_CMD+=(-v)
fi
if [[ $CLEAN == false ]]; then
    # buildiso.sh's -c disables its default clean-first behavior.
    BUILD_CMD+=(-c)
fi

printf '>>> Running:'
printf ' %q' "${BUILD_CMD[@]}"
printf '\n'
echo ""

"${BUILD_CMD[@]}"

echo ""
echo "=== ISO build complete ==="
echo "Check the out/ directory for the ISO file."
echo ""
echo "To write to USB:"
echo "  sudo dd if=out/desktop/cachyos-macpro-*.iso of=/dev/sdX bs=4M status=progress && sync"
echo ""
echo "⚠️  Remember: Always power off the Mac Pro (never reboot) for GPU init!"
