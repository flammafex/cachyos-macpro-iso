#!/bin/bash
# setup-local-repo.sh — Create the macpro pacman repo from local package files
#
# Run this after building all five authoritative local packages:
#   ./scripts/build-kernel.sh
#   ./scripts/build-macfanctld.sh
#   ./scripts/build-support.sh
#   ./scripts/build-calamares.sh
#   ./scripts/setup-local-repo.sh
#
# Package artifacts are .pkg.tar.zst on current Arch systems.  .pkg.tar.xz is
# accepted for older kernel artifacts.  Signature files are never repo inputs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_REPO="$PROJECT_DIR/local-repo"
MANIFEST="$LOCAL_REPO/macpro.manifest"

if ! command -v repo-add >/dev/null 2>&1; then
    echo "ERROR: repo-add is required to create $LOCAL_REPO/macpro.db" >&2
    exit 1
fi
if ! command -v pacman >/dev/null 2>&1; then
    echo "ERROR: pacman is required to validate local package metadata." >&2
    exit 1
fi

mkdir -p "$LOCAL_REPO"

# Keep the package suffix explicit: a .sig file must not be passed to
# repo-add as though it were a package.
shopt -s nullglob
package_files=(
    "$LOCAL_REPO"/*.pkg.tar.zst
    "$LOCAL_REPO"/*.pkg.tar.xz
)
shopt -u nullglob

if (( ${#package_files[@]} != 5 )); then
    echo "ERROR: Expected exactly five package artifacts in $LOCAL_REPO/; found ${#package_files[@]}." >&2
    printf '  %s\n' "${package_files[@]:-none}" >&2
    echo "The repo must contain linux-macpro61, matching headers, macfanctld, macpro61-support, and cachyos-calamares-next." >&2
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
calamares_package=""
kernel_version=""
headers_version=""
macfan_version=""
support_version=""
calamares_version=""
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
        cachyos-calamares-next)
            [[ -z $calamares_package ]] || { echo "ERROR: Duplicate cachyos-calamares-next package." >&2; exit 1; }
            calamares_package="$artifact"
            calamares_version="$PACKAGE_VERSION"
            ;;
        *)
            echo "ERROR: Unexpected package name $PACKAGE_NAME in $artifact." >&2
            exit 1
            ;;
    esac
done

if [[ -z $kernel_package || -z $headers_package || -z $macfan_package || -z $support_package || -z $calamares_package ]]; then
    echo "ERROR: Package set must contain linux-macpro61, matching headers, macfanctld, macpro61-support, and cachyos-calamares-next." >&2
    exit 1
fi
if [[ $kernel_version != "$headers_version" ]]; then
    echo "ERROR: Kernel version $kernel_version does not match headers version $headers_version." >&2
    exit 1
fi

echo "=== Setting up local package repo ==="
echo "Package artifacts: ${#package_files[@]}"
printf '  %s\n' "${package_files[@]}"

# Remove every old database sidecar before rebuilding it from the validated
# quintet.  repo-add creates macpro.db as a compatibility symlink.
rm -f "$LOCAL_REPO"/macpro.db* "$MANIFEST"

echo ">>> Creating repo database..."
repo-add "$LOCAL_REPO/macpro.db.tar.gz" "$kernel_package" "$headers_package" "$macfan_package" "$support_package" "$calamares_package"

if [[ ! -f "$LOCAL_REPO/macpro.db" || ! -f "$LOCAL_REPO/macpro.db.tar.gz" ]]; then
    echo "ERROR: Failed to create $LOCAL_REPO/macpro.db" >&2
    exit 1
fi

manifest_tmp=$(mktemp "$LOCAL_REPO/.macpro.manifest.XXXXXX")
trap 'rm -f -- "$manifest_tmp"' EXIT
manifest_files=(
    macpro.db
    macpro.db.tar.gz
    "${kernel_package##*/}"
    "${headers_package##*/}"
    "${macfan_package##*/}"
    "${support_package##*/}"
    "${calamares_package##*/}"
)
(
    cd "$LOCAL_REPO"
    sha256sum -- "${manifest_files[@]}"
) | LC_ALL=C sort -k2,2 > "$manifest_tmp"
mv -- "$manifest_tmp" "$MANIFEST"
trap - EXIT

echo ""
echo "=== Local repo ready ==="
echo "DB: $LOCAL_REPO/macpro.db"
echo "Manifest: $MANIFEST"
echo "Kernel: ${kernel_package##*/}"
echo "Headers: ${headers_package##*/}"
echo "Fan daemon: ${macfan_package##*/}"
echo "Fan daemon version: $macfan_version"
echo "Support: ${support_package##*/} (version $support_version)"
echo "Calamares: ${calamares_package##*/} (version $calamares_version)"
echo ""
echo "Next step: Run scripts/build-iso.sh to build the ISO"
