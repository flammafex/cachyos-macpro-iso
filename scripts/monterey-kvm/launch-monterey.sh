#!/usr/bin/env bash

set -euo pipefail
umask 077

usage() {
    printf '%s\n' \
        "Usage: APPLE_SMC_OSK=... ${0##*/} --vm-dir DIR --ovmf-code FILE --opencore-disk FILE [options]" \
        "" \
        "Launch a prepared Monterey VM using QEMU/KVM." \
        "" \
        "Required arguments:" \
        "  --vm-dir DIR          Prepared VM directory" \
        "  --ovmf-code FILE      OVMF_CODE firmware file" \
        "  --opencore-disk FILE  OpenCore disk (attached in snapshot mode)" \
        "" \
        "Optional arguments:" \
        "  --recovery            Attach the prepared writable recovery overlay" \
        "  --cpu-profile NAME    penryn or host (default: penryn)" \
        "  --vcpus N             4, 6, or 12 (default: 4)" \
        "  --memory-mib MIB      Guest memory, 2048..32768 MiB (default: 8192)" \
        "  -h, --help            Show this help" \
        "" \
        "APPLE_SMC_OSK must be set in the environment; its value is never printed." \
        "The penryn profile is the validated default; host is experimental and" \
        "not validated for portability." \
        "Networking is user-mode networking without port forwarding."
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

vm_dir=''
ovmf_code=''
opencore_disk=''
with_recovery=0
cpu_profile='penryn'
vcpus=4
memory_mib=8192

while (($# > 0)); do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --recovery)
            with_recovery=1
            shift
            ;;
        --vm-dir|--ovmf-code|--opencore-disk|--cpu-profile|--vcpus|--memory-mib|--memory)
            (($# >= 2)) || die "missing value for $1"
            option=$1
            value=$2
            shift 2
            case $option in
                --vm-dir) vm_dir=$value ;;
                --ovmf-code) ovmf_code=$value ;;
                --opencore-disk) opencore_disk=$value ;;
                --cpu-profile) cpu_profile=$value ;;
                --vcpus) vcpus=$value ;;
                --memory-mib|--memory) memory_mib=$value ;;
            esac
            ;;
        *)
            die "unknown argument: $1 (use --help)"
            ;;
    esac
done

[[ -n "${APPLE_SMC_OSK:-}" ]] || die "APPLE_SMC_OSK must be set and non-empty"
[[ -n "$vm_dir" ]] || die "--vm-dir is required"
[[ -n "$ovmf_code" ]] || die "--ovmf-code is required"
[[ -n "$opencore_disk" ]] || die "--opencore-disk is required"

case $cpu_profile in
    penryn)
        cpu_model='Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
        ;;
    host)
        cpu_model='host,kvm=on,vendor=GenuineIntel,+invtsc'
        ;;
    *)
        die "--cpu-profile must be penryn or host"
        ;;
esac

case $vcpus in
    4) cores=2; threads=2 ;;
    6) cores=3; threads=2 ;;
    12) cores=6; threads=2 ;;
    *) die "--vcpus must be 4, 6, or 12" ;;
esac

[[ "$memory_mib" =~ ^[0-9]+$ ]] || die "--memory-mib must be an integer"
((memory_mib >= 2048 && memory_mib <= 32768)) || \
    die "--memory-mib must be between 2048 and 32768"
((memory_mib >= vcpus * 1024)) || \
    die "--memory-mib is too small for $vcpus vCPUs"

require_command qemu-system-x86_64
require_command realpath

[[ -d "$vm_dir" && ! -L "$vm_dir" ]] || die "VM directory is not a real directory: $vm_dir"
ovmf_code=$(resolve_file "$ovmf_code" 'OVMF code')
opencore_disk=$(resolve_file "$opencore_disk" 'OpenCore disk')

guest_disk="$vm_dir/guest.qcow2"
ovmf_vars="$vm_dir/OVMF_VARS.fd"
recovery_disk="$vm_dir/recovery.qcow2"
require_regular_file "$guest_disk" 'guest disk'
require_regular_file "$ovmf_vars" 'writable OVMF VARS'
[[ -w "$ovmf_vars" ]] || die "writable OVMF VARS is not writable: $ovmf_vars"
if ((with_recovery)); then
    require_regular_file "$recovery_disk" 'recovery overlay'
    [[ -w "$recovery_disk" ]] || die "recovery overlay is not writable: $recovery_disk"
fi

warn_if_ignore_msrs_disabled() {
    local parameter_path='/sys/module/kvm/parameters/ignore_msrs'
    local parameter_value

    if [[ -r "$parameter_path" ]]; then
        parameter_value=$(<"$parameter_path")
        case $parameter_value in
            0|N|n|no|false|off|disabled)
                printf '%s\n' \
                    'warning: KVM ignore_msrs is observable and disabled.' \
                    'warning: choose how to enable ignore_msrs temporarily before launching; this helper will not modify host state.' \
                    >&2
                ;;
        esac
    fi
}

warn_if_ignore_msrs_disabled

qemu_args=(
    -name Monterey
    -machine q35,accel=kvm
    -m "$memory_mib"
    -smp "${vcpus},sockets=1,cores=${cores},threads=${threads}"
    -cpu "$cpu_model"
    -device "isa-applesmc,osk=${APPLE_SMC_OSK}"
    -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}"
    -drive "if=pflash,format=raw,file=${ovmf_vars}"
    -device ich9-ahci,id=sata
    -drive "id=OpenCoreBoot,if=none,format=qcow2,snapshot=on,file=${opencore_disk}"
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot
    -drive "id=GuestDisk,if=none,format=qcow2,file=${guest_disk}"
    -device ide-hd,bus=sata.4,drive=GuestDisk
    -device vmware-svga
    -display gtk,gl=off
    -netdev user,id=net0
    -device virtio-net-pci,netdev=net0,id=net0
    -monitor stdio
)

if ((with_recovery)); then
    qemu_args+=(
        -drive "id=RecoveryMedia,if=none,format=qcow2,file=${recovery_disk}"
        -device ide-hd,bus=sata.3,drive=RecoveryMedia
    )
fi

printf 'Launching Monterey VM with %s vCPUs and %s MiB memory.\n' "$vcpus" "$memory_mib"
exec qemu-system-x86_64 "${qemu_args[@]}"
