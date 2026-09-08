#!/usr/bin/env bash

set -euo pipefail
umask 077

usage() {
    printf '%s\n' \
        "Usage: ${0##*/} --vm-dir DIR --recovery-dmg FILE --ovmf-code FILE --ovmf-vars FILE --opencore-disk FILE [--disk-size SIZE]" \
        "" \
        "Create a new, isolated Monterey VM directory." \
        "" \
        "Required arguments:" \
        "  --vm-dir DIR          New, non-existent VM directory" \
        "  --recovery-dmg FILE   User-provided Apple recovery DMG" \
        "  --ovmf-code FILE      OVMF_CODE firmware file (validated, not copied)" \
        "  --ovmf-vars FILE      OVMF_VARS template to copy" \
        "  --opencore-disk FILE  User-provided OpenCore disk (validated, not copied)" \
        "" \
        "Optional arguments:" \
        "  --disk-size SIZE      Guest qcow2 size, for example 32G (default: 32G)" \
        "  -h, --help            Show this help" \
        "" \
        "The helper accepts regular files only; it never consumes a host block device."
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_regular_file() {
    local path=$1
    local label=$2

    [[ -b "$path" ]] && die "$label must not be a block device"
    [[ -f "$path" ]] || die "$label is not a regular file: $path"
    [[ -r "$path" ]] || die "$label is not readable: $path"
}

resolve_file() {
    local path=$1
    local label=$2
    local resolved

    require_regular_file "$path" "$label"
    resolved=$(realpath -e -- "$path") || die "could not resolve $label: $path"
    require_regular_file "$resolved" "$label"
    printf '%s\n' "$resolved"
}

valid_disk_size() {
    [[ "$1" =~ ^[1-9][0-9]*[KMGTP]i?B?$ ]]
}

vm_dir=''
recovery_dmg=''
ovmf_code=''
ovmf_vars=''
opencore_disk=''
disk_size='32G'

while (($# > 0)); do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --vm-dir|--recovery-dmg|--ovmf-code|--ovmf-vars|--opencore-disk|--disk-size)
            (($# >= 2)) || die "missing value for $1"
            option=$1
            value=$2
            shift 2
            case $option in
                --vm-dir) vm_dir=$value ;;
                --recovery-dmg) recovery_dmg=$value ;;
                --ovmf-code) ovmf_code=$value ;;
                --ovmf-vars) ovmf_vars=$value ;;
                --opencore-disk) opencore_disk=$value ;;
                --disk-size) disk_size=$value ;;
            esac
            ;;
        *)
            die "unknown argument: $1 (use --help)"
            ;;
    esac
done

[[ -n "$vm_dir" ]] || die "--vm-dir is required"
[[ -n "$recovery_dmg" ]] || die "--recovery-dmg is required"
[[ -n "$ovmf_code" ]] || die "--ovmf-code is required"
[[ -n "$ovmf_vars" ]] || die "--ovmf-vars is required"
[[ -n "$opencore_disk" ]] || die "--opencore-disk is required"
valid_disk_size "$disk_size" || die "invalid --disk-size: $disk_size (use a value such as 32G)"

require_command qemu-img
require_command realpath
require_command cp
require_command chmod

recovery_dmg=$(resolve_file "$recovery_dmg" 'recovery DMG')
ovmf_code=$(resolve_file "$ovmf_code" 'OVMF code')
ovmf_vars=$(resolve_file "$ovmf_vars" 'OVMF VARS')
opencore_disk=$(resolve_file "$opencore_disk" 'OpenCore disk')

[[ ! -e "$vm_dir" && ! -L "$vm_dir" ]] || die "VM directory already exists: $vm_dir"
parent_dir=$(dirname -- "$vm_dir")
[[ -d "$parent_dir" ]] || die "parent directory does not exist: $parent_dir"
[[ -w "$parent_dir" ]] || die "parent directory is not writable: $parent_dir"

mkdir -- "$vm_dir" || die "could not create VM directory: $vm_dir"
cleanup() {
    rm -rf -- "$vm_dir"
}
trap cleanup ERR INT TERM

# Run image creation from inside the VM directory so the qcow2 backing name is
# the portable relative name recovery.raw rather than a host-specific path.
(
    cd -- "$vm_dir"
    qemu-img convert -p -f dmg -O raw -- "$recovery_dmg" recovery.raw
    chmod a-w -- recovery.raw
    qemu-img create -f qcow2 -F raw -b recovery.raw recovery.qcow2
    qemu-img create -f qcow2 guest.qcow2 "$disk_size"
)

cp -- "$ovmf_vars" "$vm_dir/OVMF_VARS.fd"
chmod u+rw,go-rwx -- "$vm_dir/OVMF_VARS.fd"

trap - ERR INT TERM
printf 'Prepared a new Monterey VM directory: %s\n' "$vm_dir"
printf 'Guest disk size: %s\n' "$disk_size"
