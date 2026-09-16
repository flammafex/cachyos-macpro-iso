#!/bin/bash
set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || fail 'Package verification must run as root.'
(( $# == 16 )) || fail 'Usage: macpro-verify-packages.sh --kernel-name NAME --kernel-version VERSION --headers-name NAME --headers-version VERSION --macfanctld-name NAME --macfanctld-version VERSION --support-name NAME --support-version VERSION'

declare -A expected=()
while (( $# > 0 )); do
    case "$1" in
        --kernel-name) expected[kernel_name]="$2" ;;
        --kernel-version) expected[kernel_version]="$2" ;;
        --headers-name) expected[headers_name]="$2" ;;
        --headers-version) expected[headers_version]="$2" ;;
        --macfanctld-name) expected[macfanctld_name]="$2" ;;
        --macfanctld-version) expected[macfanctld_version]="$2" ;;
        --support-name) expected[support_name]="$2" ;;
        --support-version) expected[support_version]="$2" ;;
        *) fail "Unexpected verification argument: $1" ;;
    esac
    shift 2
done

for key in kernel_name kernel_version headers_name headers_version macfanctld_name macfanctld_version support_name support_version; do
    value=${expected[$key]:-}
    [[ -n "$value" && "$value" != *@@* ]] || fail "Unresolved or empty verification value: $key"
done

[[ ${expected[kernel_name]} == linux-macpro61 ]] || fail 'Unexpected kernel package name.'
[[ ${expected[headers_name]} == linux-macpro61-headers ]] || fail 'Unexpected headers package name.'
[[ ${expected[macfanctld_name]} == macfanctld ]] || fail 'Unexpected macfanctld package name.'
[[ ${expected[support_name]} == macpro61-support ]] || fail 'Unexpected support package name.'

verify_package() {
    local key="$1" expected_name="$2" expected_version="$3" actual_name actual_version
    local -a records=()
    mapfile -t records < <(pacman -Q "$expected_name" 2>/dev/null) || fail "pacman could not query $expected_name"
    (( ${#records[@]} == 1 )) || fail "Expected exactly one installed record for $expected_name"
    read -r actual_name actual_version _ <<< "${records[0]}"
    [[ "$actual_name" == "$expected_name" && "$actual_version" == "$expected_version" ]] || \
        fail "$key package mismatch: expected $expected_name $expected_version, got ${records[0]}"
}

verify_package kernel "${expected[kernel_name]}" "${expected[kernel_version]}"
verify_package headers "${expected[headers_name]}" "${expected[headers_version]}"
verify_package macfanctld "${expected[macfanctld_name]}" "${expected[macfanctld_version]}"
verify_package support "${expected[support_name]}" "${expected[support_version]}"

# The kernel package keeps its canonical image under /usr/lib/modules.
# Calamares' later mkinitcpio job expects it in /boot already.
mapfile -t kernel_images < <(
    pacman -Qlq linux-macpro61 2>/dev/null |
    grep -E '^/usr/lib/modules/[^/]+/vmlinuz$' || true
)

(( ${#kernel_images[@]} == 1 )) || \
    fail "Expected exactly one linux-macpro61 kernel image; found ${#kernel_images[@]}"

[[ -s "${kernel_images[0]}" ]] || \
    fail "linux-macpro61 kernel image is missing or empty: ${kernel_images[0]}"

install -Dm0644 \
    "${kernel_images[0]}" \
    /boot/vmlinuz-linux-macpro61

cmp -s \
    "${kernel_images[0]}" \
    /boot/vmlinuz-linux-macpro61 || \
    fail 'The /boot Mac Pro kernel does not match the installed package image.'

# CachyOS pacstrap currently leaves its stock kernels installed before our
# offline package stage. They must be gone before the global mkinitcpio job,
# otherwise the small shared ESP fills with several kernel/initramfs sets.
mapfile -t installed_packages < <(pacman -Qq 2>/dev/null) || \
    fail 'pacman could not enumerate installed packages'

stock_kernels=()
for installed_package in "${installed_packages[@]}"; do
    case "$installed_package" in
        linux-cachyos*)
            stock_kernels+=("$installed_package")
            ;;
    esac
done

if (( ${#stock_kernels[@]} )); then
    printf 'Removing stock CachyOS kernel packages: %s\n' \
        "${stock_kernels[*]}" >&2

    pacman -R --noconfirm -- "${stock_kernels[@]}" || \
        fail 'Could not remove stock CachyOS kernel packages.'
fi

# Remove any stale stock presets/files left by an interrupted prior attempt.
rm -f -- \
    /etc/mkinitcpio.d/linux-cachyos*.preset \
    /boot/vmlinuz-linux-cachyos* \
    /boot/initramfs-linux-cachyos*.img

installed_packages=$(pacman -Qq 2>/dev/null) || \
    fail 'pacman could not re-enumerate installed packages'

while IFS= read -r installed_package; do
    case "$installed_package" in
        linux-cachyos*)
            fail "Stock CachyOS kernel package survived cleanup: $installed_package"
            ;;
    esac
done <<< "$installed_packages"

[[ -s /boot/vmlinuz-linux-macpro61 ]] || \
    fail 'Mac Pro kernel was not seeded into /boot.'

[[ -f /etc/mkinitcpio.d/linux-macpro61.preset ]] || \
    fail 'linux-macpro61 mkinitcpio preset is missing.'

