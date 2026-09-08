#!/bin/bash
set -euo pipefail

source /usr/local/lib/macpro-package-bundle.sh

BUNDLE_DIR=/opt/macpro-packages
MANIFEST="$BUNDLE_DIR/packages.sha256"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || fail 'Package staging must run as root.'
(( $# == 1 )) || fail 'Usage: macpro-stage-packages.sh --root=TARGET_ROOT'
case "$1" in
    --root=*) target_root=${1#--root=} ;;
    *) fail 'The target root must be supplied as --root=TARGET_ROOT.' ;;
esac
[[ -n "$target_root" && "$target_root" == /* ]] || fail 'Target root must be an absolute path.'
[[ "$target_root" != *$'\n'* && "$target_root" != *$'\r'* ]] || fail 'Target root contains a control character.'
[[ "$target_root" != */../* && "$target_root" != ../* && "$target_root" != */.. ]] || fail 'Target root contains traversal.'
[[ ! -L "$target_root" && -d "$target_root" ]] || fail 'Target root must be an existing, non-symlink directory.'

target_root=$(realpath -e -- "$target_root")
[[ "$target_root" != / ]] || fail 'Refusing to stage packages into the live root.'
[[ "$target_root" != /opt/macpro-packages && "$target_root" != /opt/macpro-packages/* ]] || fail 'Refusing to use the live package bundle as target root.'
[[ -d "$target_root/var" ]] || fail 'Target root does not contain a var directory.'

macpro_validate_bundle "$BUNDLE_DIR" "$MANIFEST"
cache_dir="$target_root/var/cache/calamares/packages"
[[ ! -e "$cache_dir" || ! -L "$cache_dir" ]] || fail 'Target package cache must not be a symlink.'
mkdir -p -- "$cache_dir"

verification_source=/usr/local/bin/macpro-verify-packages.sh
verification_destination="$cache_dir/macpro-verify-packages.sh"
[[ -f "$verification_source" && ! -L "$verification_source" ]] || fail "Verification helper is missing: $verification_source"
[[ ! -e "$verification_destination" && ! -L "$verification_destination" ]] || \
    fail "Target verification helper path already exists: $verification_destination"

shopt -s nullglob
existing_packages=("$cache_dir"/*.pkg.tar.zst "$cache_dir"/*.pkg.tar.xz)
shopt -u nullglob
for package_path in "${existing_packages[@]}"; do
    package_name=${package_path##*/}
    case "$package_name" in
        "$MACPRO_KERNEL_PACKAGE"|"$MACPRO_HEADERS_PACKAGE"|"$MACPRO_MACFANCTLD_PACKAGE"|"$MACPRO_SUPPORT_PACKAGE") ;;
        *) fail "Unexpected pre-existing target package: $package_name" ;;
    esac
done

for package_name in "$MACPRO_KERNEL_PACKAGE" "$MACPRO_HEADERS_PACKAGE" "$MACPRO_MACFANCTLD_PACKAGE" "$MACPRO_SUPPORT_PACKAGE"; do
    destination="$cache_dir/$package_name"
    [[ ! -L "$destination" ]] || fail "Target package path is a symlink: $destination"
    cp -- "$BUNDLE_DIR/$package_name" "$destination"
done
cp -- "$MANIFEST" "$cache_dir/packages.sha256"
macpro_validate_bundle "$cache_dir" "$cache_dir/packages.sha256"
cp -- "$verification_source" "$verification_destination"
chmod 0555 -- "$verification_destination"
[[ -f "$verification_destination" && ! -L "$verification_destination" && -x "$verification_destination" ]] || \
    fail "Target verification helper is not a safe executable: $verification_destination"
(cd "$cache_dir" && sha256sum -c -- packages.sha256 >/dev/null) || \
    fail 'Target package checksum validation failed after staging.'
