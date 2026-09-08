#!/bin/bash
set -euo pipefail

source /usr/local/lib/macpro-package-bundle.sh

BUNDLE_DIR=/opt/macpro-packages
MANIFEST="$BUNDLE_DIR/packages.sha256"

if (( EUID == 0 )); then
    printf '%s\n' 'ERROR: calamares-online.sh must be launched as an unprivileged user.' >&2
    exit 1
fi
if [[ ! -d /sys/firmware/efi ]]; then
    printf '%s\n' 'ERROR: Calamares requires a UEFI boot.' >&2
    exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
    printf 'ERROR: Package manifest is missing: %s\n' "$MANIFEST" >&2
    exit 1
fi

macpro_validate_bundle "$BUNDLE_DIR" "$MANIFEST"

exec /usr/local/bin/pkexec-wrapper /usr/local/bin/macpro-calamares-root.sh
