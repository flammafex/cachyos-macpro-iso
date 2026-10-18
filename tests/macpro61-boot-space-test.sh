#!/bin/bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bootctl="$repo_root/packages/macpro61-support/files/usr/lib/macpro61-support/macpro61-bootctl"
# shellcheck source=/dev/null
source "$bootctl"

MiB=$((1024 * 1024))
kernel_size=$((16 * MiB))
initramfs_size=$((40 * MiB))
required=$(estimate_required_bytes "$kernel_size" "$initramfs_size")
[[ $required -eq $((70 * MiB)) ]] || {
    printf 'unexpected required space: %s bytes (expected %s)\n' "$required" "$((70 * MiB))" >&2
    exit 1
}

# About 76 MiB is enough for this estimate; a 69 MiB budget is not.
available=$((76 * MiB))
require_estimated_space "$kernel_size" "$initramfs_size" "$available"
available=$((69 * MiB))
if output=$(require_estimated_space "$kernel_size" "$initramfs_size" "$available" 2>&1); then
    printf 'insufficient-space case unexpectedly passed\n' >&2
    exit 1
fi
for diagnostic in \
    'old kernel: 16777216 bytes' \
    'temporary initramfs estimate at 125% of old image: 52428800 bytes' \
    'metadata margin: 4194304 bytes' \
    '73400320 bytes required' \
    '72351744 bytes available' \
    'cannot guarantee space'; do
    [[ $output == *"$diagnostic"* ]] || {
        printf 'missing diagnostic component %q in: %s\n' "$diagnostic" "$output" >&2
        exit 1
    }
done

# Verify remains read-only with respect to generic loader-entry cleanup.
verify_body=$(sed -n '/^verify() {/,/^}/p' "$bootctl")
if [[ $verify_body == *cleanup_loader_entries* ]]; then
    printf 'verify still invokes cleanup_loader_entries\n' >&2
    exit 1
fi

printf 'macpro61 boot space tests passed (required=%s bytes, 76 MiB pass, 69 MiB fail)\n' "$required"
