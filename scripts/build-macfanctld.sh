#!/bin/bash
# build-macfanctld.sh — Build and stage the authoritative macfanctld package
#
# Usage:
#   MACFANCTLD_SOURCE_DIR=/path/to/macfanctld ./scripts/build-macfanctld.sh
#
# MACFANCTLD_SOURCE_DIR defaults to ../macfanctld relative to this project.
# The source directory is expected to follow the upstream layout
# (MikaelStrom/macfanctld: macfanctl.c, control.c, config.c, Makefile,
# macfanctld.1) plus the Arch extras kept alongside it: macfanctl.conf,
# macfanctld.service, and macfanctld.install.
#
# If SOURCE_DIR/PKGBUILD exists it is used as-is (legacy AUR-style checkout).
# Otherwise a PKGBUILD is generated in an isolated temporary build directory
# from the local sources, so no PKGBUILD needs to live in the source repo and
# no download happens at build time.
# Run scripts/build-support.sh next, then scripts/setup-local-repo.sh and
# scripts/build-iso.sh.
# The build happens in an isolated temporary directory, so stale package
# files in the source tree cannot be mistaken for build output.
# This script deliberately does not request dependency synchronization: it
# never installs packages on the host and must be run as a non-root user.
#
# PKGVER/PKGREL default to the last shipped tuned curve (0.6-3) and can be
# overridden with MACFANCTLD_PKGVER / MACFANCTLD_PKGREL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="${MACFANCTLD_SOURCE_DIR:-$PROJECT_DIR/../macfanctld}"
LOCAL_REPO="$PROJECT_DIR/local-repo"
PKGVER="${MACFANCTLD_PKGVER:-0.6}"
PKGREL="${MACFANCTLD_PKGREL:-3}"

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    printf 'Usage: MACFANCTLD_SOURCE_DIR=/path/to/macfanctld %s\n' "${BASH_SOURCE[0]}"
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

stage_artifact() {
    local build_dir="$1"
    shopt -s nullglob
    resulting_artifacts=(
        "$build_dir"/*-x86_64.pkg.tar.zst
        "$build_dir"/*-x86_64.pkg.tar.xz
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
}

# Legacy path: authoritative source already carries a PKGBUILD (e.g. an
# AUR-style checkout that fetches the upstream tarball). Build it as-is.
if [[ -f "$SOURCE_DIR/PKGBUILD" ]]; then
    # This parses package metadata only; it does not run the package build.
    echo ">>> Validating source PKGBUILD: $SOURCE_DIR/PKGBUILD"
    if ! (cd "$SOURCE_DIR" && makepkg --printsrcinfo >/dev/null); then
        echo "ERROR: Invalid macfanctld PKGBUILD: $SOURCE_DIR/PKGBUILD" >&2
        exit 1
    fi

    BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/macfanctld-build.XXXXXX")
    trap 'rm -rf -- "$BUILD_DIR"' EXIT

    echo "=== Building authoritative macfanctld package (from source PKGBUILD) ==="
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

    stage_artifact "$BUILD_DIR"
    exit 0
fi

# Upstream-layout path: SOURCE_DIR holds the C sources plus Arch extras, but
# no PKGBUILD. Generate one from the local tree.
echo ">>> No PKGBUILD in $SOURCE_DIR; generating one from upstream layout."

required_sources=(
    macfanctl.c control.c config.c control.h config.h
    macfanctld.1 macfanctl.conf macfanctld.service macfanctld.install
)
missing=()
for required in "${required_sources[@]}"; do
    [[ -f "$SOURCE_DIR/$required" ]] || missing+=("$required")
done
if (( ${#missing[@]} > 0 )); then
    echo "ERROR: macfanctld source directory is missing required files:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/macfanctld-build.XXXXXX")
trap 'rm -rf -- "$BUILD_DIR"' EXIT

echo "=== Building authoritative macfanctld package (from upstream layout) ==="
echo "Source: $SOURCE_DIR"
echo "Output: $LOCAL_REPO"
echo "Build directory: $BUILD_DIR"
echo "Version: $PKGVER-$PKGREL"

mkdir -p "$BUILD_DIR/upstream"
cp -a "$SOURCE_DIR"/. "$BUILD_DIR/upstream/"
rm -rf -- "$BUILD_DIR/upstream/.git"
shopt -s nullglob
stale_upstream=(
    "$BUILD_DIR/upstream"/*.pkg.tar.zst
    "$BUILD_DIR/upstream"/*.pkg.tar.xz
)
shopt -u nullglob
(( ${#stale_upstream[@]} == 0 )) || rm -f -- "${stale_upstream[@]}"
cp -- "$SOURCE_DIR/macfanctld.install" "$BUILD_DIR/macfanctld.install"

# The generated PKGBUILD builds only from the local upstream copy staged
# above (no network download). The upstream Makefile's install target assumes
# Debian helpers, so only `make` is used and files are installed manually to
# match the previous Arch layout (/usr/bin binary, systemd unit, man page).
cat > "$BUILD_DIR/PKGBUILD" <<EOF
pkgname=macfanctld
pkgver=$PKGVER
pkgrel=$PKGREL
arch=('x86_64')
pkgdesc="Fan control daemon for MacBook"
url="https://github.com/MikaelStrom/macfanctld"
license=('GPL3')
makedepends=('gcc')
depends=('glibc')
backup=('etc/macfanctl.conf')
install=macfanctld.install
source=()
sha256sums=()

build() {
  make -C "\$startdir/upstream"
}

package() {
  install -Dm755 "\$startdir/upstream/macfanctld" "\$pkgdir/usr/bin/macfanctld"
  install -Dm644 "\$startdir/upstream/macfanctl.conf" "\$pkgdir/etc/macfanctl.conf"
  install -Dm644 "\$startdir/upstream/macfanctld.service" "\$pkgdir/usr/lib/systemd/system/macfanctld.service"
  install -d "\$pkgdir/usr/share/man/man1"
  gzip -9c "\$startdir/upstream/macfanctld.1" > "\$pkgdir/usr/share/man/man1/macfanctld.1.gz"
  chmod 644 "\$pkgdir/usr/share/man/man1/macfanctld.1.gz"
}
EOF

# This parses package metadata only; it does not run the package build.
echo ">>> Validating generated PKGBUILD"
if ! (cd "$BUILD_DIR" && makepkg --printsrcinfo >/dev/null); then
    echo "ERROR: Generated macfanctld PKGBUILD failed validation." >&2
    exit 1
fi

cd "$BUILD_DIR"
echo ">>> Running makepkg (without dependency installation) ..."
makepkg --noconfirm

stage_artifact "$BUILD_DIR"
