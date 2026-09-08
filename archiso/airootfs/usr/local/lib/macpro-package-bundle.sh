#!/bin/bash
set -euo pipefail

macpro_validate_bundle() {
    local bundle_dir="$1"
    local manifest="$2"
    local line hash package_name package_path
    local metadata metadata_line metadata_value actual_name actual_version actual_arch expected_name
    local kernel_version='' headers_version=''
    local kernel_count=0 headers_count=0 macfan_count=0 support_count=0
    local -a manifest_names=() package_paths=() bundle_entries=()
    declare -A manifest_seen=()

    [[ -d "$bundle_dir" && ! -L "$bundle_dir" ]] || {
        printf 'ERROR: Invalid package bundle directory: %s\n' "$bundle_dir" >&2
        return 1
    }
    [[ "$manifest" == "$bundle_dir/packages.sha256" ]] || {
        printf '%s\n' 'ERROR: Package manifest must be packages.sha256 in the bundle.' >&2
        return 1
    }
    [[ -f "$manifest" && ! -L "$manifest" ]] || {
        printf 'ERROR: Package manifest is missing or not a regular file: %s\n' "$manifest" >&2
        return 1
    }
    command -v pacman >/dev/null 2>&1 || {
        printf '%s\n' 'ERROR: pacman is required to validate package metadata.' >&2
        return 1
    }

    shopt -s nullglob
    package_paths=("$bundle_dir"/*.pkg.tar.zst "$bundle_dir"/*.pkg.tar.xz)
    bundle_entries=("$bundle_dir"/* "$bundle_dir"/.[!.]* "$bundle_dir"/..?*)
    shopt -u nullglob
    (( ${#package_paths[@]} == 4 )) || {
        printf 'ERROR: Expected exactly four package artifacts in %s; found %s.\n' \
            "$bundle_dir" "${#package_paths[@]}" >&2
        return 1
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || {
            printf '%s\n' 'ERROR: Package manifest contains a blank line.' >&2
            return 1
        }
        [[ "$line" =~ ^([[:xdigit:]]{64})[[:space:]][[:space:]]([^[:space:]]+)$ ]] || {
            printf 'ERROR: Invalid package manifest line: %s\n' "$line" >&2
            return 1
        }
        hash=${BASH_REMATCH[1]}
        package_name=${BASH_REMATCH[2]}
        [[ "$package_name" != */* && "$package_name" != *\\* && "$package_name" != . && "$package_name" != .. ]] || {
            printf 'ERROR: Unsafe package name in manifest: %s\n' "$package_name" >&2
            return 1
        }
        [[ "$package_name" == *.pkg.tar.zst || "$package_name" == *.pkg.tar.xz ]] || {
            printf 'ERROR: Manifest is not package-only: %s\n' "$package_name" >&2
            return 1
        }
        [[ -z ${manifest_seen[$package_name]+present} ]] || {
            printf 'ERROR: Duplicate package in manifest: %s\n' "$package_name" >&2
            return 1
        }
        manifest_seen[$package_name]="$hash"
        manifest_names+=("$package_name")
        case "$package_name" in
            linux-macpro61-headers-*.pkg.tar.zst|linux-macpro61-headers-*.pkg.tar.xz)
                ((headers_count += 1)) ;;
            linux-macpro61-*.pkg.tar.zst|linux-macpro61-*.pkg.tar.xz)
                ((kernel_count += 1)) ;;
            macfanctld-*.pkg.tar.zst|macfanctld-*.pkg.tar.xz)
                ((macfan_count += 1)) ;;
            macpro61-support-*.pkg.tar.zst|macpro61-support-*.pkg.tar.xz)
                ((support_count += 1)) ;;
            *)
                printf 'ERROR: Unexpected package name in manifest: %s\n' "$package_name" >&2
                return 1
                ;;
        esac
    done < "$manifest"

    (( ${#manifest_names[@]} == 4 && kernel_count == 1 && headers_count == 1 && macfan_count == 1 && support_count == 1 )) || {
        printf '%s\n' 'ERROR: Manifest must contain one kernel, matching headers, macfanctld, and macpro61-support package.' >&2
        return 1
    }

    for package_path in "${package_paths[@]}"; do
        package_name=${package_path##*/}
        [[ -f "$package_path" && ! -L "$package_path" ]] || {
            printf 'ERROR: Package is missing or not a regular file: %s\n' "$package_path" >&2
            return 1
        }
        [[ -n ${manifest_seen[$package_name]+present} ]] || {
            printf 'ERROR: Unlisted package artifact in bundle: %s\n' "$package_name" >&2
            return 1
        }
        case "$package_name" in
            linux-macpro61-headers-*) expected_name=linux-macpro61-headers ;;
            linux-macpro61-*) expected_name=linux-macpro61 ;;
            macfanctld-*) expected_name=macfanctld ;;
            macpro61-support-*) expected_name=macpro61-support ;;
            *) printf 'ERROR: Unexpected package artifact in bundle: %s\n' "$package_name" >&2; return 1 ;;
        esac
        metadata=$(LC_ALL=C pacman -Qp --info "$package_path" 2>/dev/null) || {
            printf 'ERROR: Cannot read package metadata: %s\n' "$package_name" >&2
            return 1
        }
        actual_name=''
        actual_version=''
        actual_arch=''
        while IFS= read -r metadata_line; do
            case "$metadata_line" in
                Name*:*) metadata_value=${metadata_line#*:}; actual_name="${metadata_value#"${metadata_value%%[![:space:]]*}"}" ;;
                Version*:*) metadata_value=${metadata_line#*:}; actual_version="${metadata_value#"${metadata_value%%[![:space:]]*}"}" ;;
                Architecture*:*) metadata_value=${metadata_line#*:}; actual_arch="${metadata_value#"${metadata_value%%[![:space:]]*}"}" ;;
            esac
        done <<< "$metadata"
        [[ "$actual_name" == "$expected_name" && "$actual_arch" == x86_64 && -n "$actual_version" ]] || {
            printf 'ERROR: Package metadata does not match expected bundle package: %s\n' "$package_name" >&2
            return 1
        }
        case "$package_name" in
            "${actual_name}-${actual_version}-${actual_arch}.pkg.tar.zst"|"${actual_name}-${actual_version}-${actual_arch}.pkg.tar.xz") ;;
            *) printf 'ERROR: Package filename does not match metadata: %s\n' "$package_name" >&2; return 1 ;;
        esac
        case "$actual_name" in
            linux-macpro61) kernel_version="$actual_version" ;;
            linux-macpro61-headers) headers_version="$actual_version" ;;
        esac
    done
    [[ -n "$kernel_version" && "$kernel_version" == "$headers_version" ]] || {
        printf 'ERROR: Kernel and headers package versions do not match.\n' >&2
        return 1
    }
    for package_path in "${bundle_entries[@]}"; do
        package_name=${package_path##*/}
        [[ "$package_name" == packages.sha256 || -n ${manifest_seen[$package_name]+present} ]] || {
            printf 'ERROR: Unexpected file in package bundle: %s\n' "$package_path" >&2
            return 1
        }
        [[ -f "$package_path" && ! -L "$package_path" ]] || {
            printf 'ERROR: Unexpected non-file bundle entry: %s\n' "$package_path" >&2
            return 1
        }
    done

    (cd "$bundle_dir" && sha256sum -c -- packages.sha256) || {
        printf 'ERROR: Package checksum validation failed in %s.\n' "$bundle_dir" >&2
        return 1
    }

    MACPRO_KERNEL_PACKAGE=''
    MACPRO_HEADERS_PACKAGE=''
    MACPRO_MACFANCTLD_PACKAGE=''
    MACPRO_SUPPORT_PACKAGE=''
    for package_name in "${manifest_names[@]}"; do
        case "$package_name" in
            linux-macpro61-headers-*) MACPRO_HEADERS_PACKAGE="$package_name" ;;
            linux-macpro61-*) MACPRO_KERNEL_PACKAGE="$package_name" ;;
            macfanctld-*) MACPRO_MACFANCTLD_PACKAGE="$package_name" ;;
            macpro61-support-*) MACPRO_SUPPORT_PACKAGE="$package_name" ;;
        esac
    done
}
