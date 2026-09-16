#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

error_function() {
    if [[ -p $logpipe ]]; then
        rm "$logpipe"
    fi
    # first exit all subshells, then print the error
    if (( ! BASH_SUBSHELL )); then
        error "A failure occurred in %s()." "$1"
        plain "Aborting..."
    fi
    umount_fs
    umount_img
    exit 2
}

run_safe() {
    local restoretrap func="$1"
    set -e
    set -E
    restoretrap=$(trap -p ERR)
    trap 'error_function $func' ERR

    if ${verbose}; then
        run_log "$func"
    else
        "$func"
    fi

    eval $restoretrap
    set +E
    set +e
}

check_umount() {
    if mountpoint -q "$1"; then
        umount -l "$1"
    fi
}

trap_exit() {
    local sig=$1; shift
    error "$@"
    umount_fs
    trap -- "$sig"
    kill "-$sig" "$$"
}

generate_motd() {
    cat << 'EOF' > ${src_dir}/archiso/airootfs/etc/motd
This ISO is based on ArchLinux ISO modified to provide Installation Environment for [38;2;23;147;209mCachyOS[0m.
https://cachyos.org

CachyOS Archiso Sources:
https://github.com/cachyos/cachyos-live-iso

ArchLinux ISO Source:
https://gitlab.archlinux.org/archlinux/archiso

Calamares is used as GUI installer:
https://github.com/calamares/calamares

Live environment will start now and let you install [38;2;23;147;209mCachyOS[0m to disk.

Getting help at the forum: https://discuss.cachyos.org

Welcome to your [38;2;23;147;209mCachyOS[0m!

[41m [41m [41m [40m [44m [40m [41m [46m [45m [41m [46m [43m [41m [44m [45m [40m [44m [40m [41m [44m [41m [41m [46m [42m [41m [44m [43m [41m [45m [40m [40m [44m [40m [41m [44m [42m [41m [46m [44m [41m [46m [47m [0m
EOF
}

fetch_cachyos_mirrorlist() {
    mkdir -p ${src_dir}/archiso/airootfs/etc/pacman.d
    local _mirrorlist_url="https://github.com/CachyOS/CachyOS-PKGBUILDS/raw/master/cachyos-mirrorlist/cachyos-mirrorlist"

    curl -sSL "${_mirrorlist_url}" > ${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist
}

generate_environment() {
    local _profile="$1"
    if [ "$_profile" == "desktop" ]; then
        cat << 'EOF' > ${src_dir}/archiso/airootfs/etc/environment
ZPOOL_VDEV_NAME_PATH=1
EOF
    fi
}

generate_version_tag() {
    local _profile="$1"
    local _version="$2"
    if [ "$_profile" == "desktop" ]; then
        echo "${_version}" > ${src_dir}/archiso/airootfs/etc/version-tag
    fi
}

generate_edition_tag() {
    local _edition="$1"
    echo "${_edition}" > ${src_dir}/archiso/airootfs/etc/edition-tag
}

modify_mkarchiso() {
    local _mkarchiso="$1"

    if [[ ! -f $_mkarchiso || ! -r $_mkarchiso ]]; then
        die "mkarchiso copy is missing or unreadable: [%s]" "$_mkarchiso"
    fi

    if ! grep -q 'archlinux-keyring-wkd-sync.timer' "$_mkarchiso"; then
        msg "Patching mkarchiso with disabled arch keyrings timer..."

        sed 's/_run_once _make_customize_airootfs/_run_once _make_customize_airootfs\n\trm -f "${pacstrap_dir}\/usr\/lib\/systemd\/system\/timers.target.wants\/archlinux-keyring-wkd-sync.timer"\n/' -i "$_mkarchiso"
    else
        msg "mkarchiso is already patched!"
    fi

    if ! grep -q 'archlinux-keyring-wkd-sync.timer' "$_mkarchiso"; then
        die "Unable to apply the keyring timer change to [%s]" "$_mkarchiso"
    fi
}

prepare_profile(){
    profile=$1

    info "Profile: [%s]" "${profile}"

    local _iso_version="$(date +%y%m%d)"
    # Fetch up-to-date version of CachyOS repo mirrorlist
    fetch_cachyos_mirrorlist

    generate_motd

    rm -f ${src_dir}/archiso/airootfs/etc/systemd/system/display-manager.service
    if [ "$profile" == "desktop" ]; then
        cp ${src_dir}/archiso/packages_desktop.x86_64 ${src_dir}/archiso/packages.x86_64
        ln -sf /usr/lib/systemd/system/plasmalogin.service ${src_dir}/archiso/airootfs/etc/systemd/system/display-manager.service
    else
        die "Unknown profile: [%s]" "${profile}"
    fi

    generate_environment "${profile}"

    # Write out version to be able to check ISO version
    generate_version_tag "${profile}" "${_iso_version}"

    # Write out edition to be able to check ISO edition
    generate_edition_tag "${profile}"

}

literal_token_count() {
    local _file="$1" _token="$2"
    awk -v needle="$_token" '
        {
            rest=$0
            while ((position=index(rest, needle)) != 0) {
                count++
                rest=substr(rest, position + length(needle))
            }
        }
        END { print count + 0 }
    ' "$_file"
}

render_calamares_token() {
    local _file="$1" _token="$2" _value="$3" _count
    _count=$(literal_token_count "$_file" "$_token")
    (( _count == 1 )) || die "Expected exactly one [%s] in [%s], found [%s]" "$_token" "$_file" "$_count"
    sed -i "s|${_token}|${_value}|g" "$_file"
}

reject_unresolved_calamares_tokens() {
    local _file="$1" _allowed_token="${2:-}"
    awk -v allowed="$_allowed_token" '
        {
            rest=$0
            while (match(rest, /@@[A-Z0-9_]+@@/)) {
                token=substr(rest, RSTART, RLENGTH)
                if (token != allowed) bad=1
                rest=substr(rest, RSTART + RLENGTH)
            }
        }
        END { exit bad + 0 }
    ' "$_file" || die "Unresolved Calamares template token in [%s]" "$_file"
}

stage_calamares_bundle() (
    set -euo pipefail

    local _repo_dir="${src_dir}/local-repo"
    local _manifest="${_repo_dir}/macpro.manifest"
    local _staged_root="${work_dir}/archiso/airootfs"
    local _bundle_dir="${_staged_root}/opt/macpro-packages"
    local _module_dir="${_staged_root}/etc/calamares/modules"
    local _netinstall_source_dir="${_staged_root}/usr/local/share/macpro-calamares"
    local _metadata _line _value _artifact _artifact_name _package_name
    local _package_paths _package_path
    local _kernel_package='' _headers_package='' _macfan_package='' _support_package=''
    local _kernel_version='' _headers_version='' _macfan_version='' _support_version=''
    local _package_arch=''
    local -a _package_files=() _bundle_candidates=() _calamares_override=() _staged_packages=() _staged_package_paths=() _module_files=() _netinstall_files=()

    command -v pacman >/dev/null 2>&1 || die 'pacman is required for local package metadata validation'
    command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required for package manifest validation'
    [[ -f "$_manifest" && ! -L "$_manifest" ]] || die 'Local repository manifest is missing: [%s]' "$_manifest"
    (cd "$_repo_dir" && sha256sum -c -- macpro.manifest >/dev/null) || \
        die 'Local repository checksum manifest validation failed: [%s]' "$_manifest"

    shopt -s nullglob
    _package_files=("$_repo_dir"/*.pkg.tar.zst "$_repo_dir"/*.pkg.tar.xz)
    _calamares_override=("$_repo_dir"/cachyos-calamares-next-*.pkg.tar.zst "$_repo_dir"/cachyos-calamares-next-*.pkg.tar.xz)
    shopt -u nullglob
    (( ${#_calamares_override[@]} == 1 )) || die 'Expected exactly one calamares installer override archive, found [%s]' "${#_calamares_override[@]}"
    # The live-only Calamares override rides the pacman server but must never
    # enter the target offline bundle: cull it before the quartet check.
    _bundle_candidates=()
    for _artifact in "${_package_files[@]}"; do
        [[ ${_artifact##*/} == cachyos-calamares-next-*.pkg.tar.* ]] || _bundle_candidates+=("$_artifact")
    done
    _package_files=("${_bundle_candidates[@]}")
    (( ${#_package_files[@]} == 4 )) || die 'Expected exactly four local package archives, found [%s]' "${#_package_files[@]}"

    read_package_metadata() {
        local _file="$1"
        if ! _metadata=$(LC_ALL=C pacman -Qp --info "$_file" 2>/dev/null); then
            die 'Cannot read pacman metadata from [%s]' "$_file"
        fi
        CALA_PACKAGE_NAME=''
        CALA_PACKAGE_VERSION=''
        CALA_PACKAGE_ARCH=''
        while IFS= read -r _line; do
            case "$_line" in
                Name*:*) _value=${_line#*:}; CALA_PACKAGE_NAME="${_value#"${_value%%[![:space:]]*}"}" ;;
                Version*:*) _value=${_line#*:}; CALA_PACKAGE_VERSION="${_value#"${_value%%[![:space:]]*}"}" ;;
                Architecture*:*) _value=${_line#*:}; CALA_PACKAGE_ARCH="${_value#"${_value%%[![:space:]]*}"}" ;;
            esac
        done <<< "$_metadata"
        [[ -n "$CALA_PACKAGE_NAME" && -n "$CALA_PACKAGE_VERSION" && -n "$CALA_PACKAGE_ARCH" ]] || \
            die 'Incomplete pacman metadata in [%s]' "$_file"
    }

    for _artifact in "${_package_files[@]}"; do
        _artifact_name=${_artifact##*/}
        [[ "$_artifact_name" =~ ^[[:alnum:]][[:alnum:]_.+@:-]*\.pkg\.tar\.(zst|xz)$ ]] || \
            die 'Unsafe package archive name: [%s]' "$_artifact_name"
        [[ "$_artifact_name" != *..* ]] || die 'Unsafe package archive name: [%s]' "$_artifact_name"
        read_package_metadata "$_artifact"
        case "$_artifact_name" in
            "${CALA_PACKAGE_NAME}-${CALA_PACKAGE_VERSION}-${CALA_PACKAGE_ARCH}.pkg.tar.zst"|"${CALA_PACKAGE_NAME}-${CALA_PACKAGE_VERSION}-${CALA_PACKAGE_ARCH}.pkg.tar.xz") ;;
            *) die 'Package filename does not match metadata: [%s]' "$_artifact_name" ;;
        esac
        [[ "$CALA_PACKAGE_ARCH" == x86_64 ]] || die 'Package [%s] is not x86_64' "$_artifact_name"
        [[ "$CALA_PACKAGE_VERSION" =~ ^[[:alnum:]][[:alnum:]_.+:%~-]*$ ]] || \
            die 'Unsafe package version in [%s]: [%s]' "$_artifact_name" "$CALA_PACKAGE_VERSION"
        [[ "$CALA_PACKAGE_VERSION" != *..* ]] || die 'Unsafe package version in [%s]: [%s]' "$_artifact_name" "$CALA_PACKAGE_VERSION"
        case "$CALA_PACKAGE_NAME" in
            linux-macpro61)
                [[ -z "$_kernel_package" ]] || die 'Duplicate linux-macpro61 package archive'
                _kernel_package="$_artifact"
                _kernel_version="$CALA_PACKAGE_VERSION"
                ;;
            linux-macpro61-headers)
                [[ -z "$_headers_package" ]] || die 'Duplicate linux-macpro61-headers package archive'
                _headers_package="$_artifact"
                _headers_version="$CALA_PACKAGE_VERSION"
                ;;
            macfanctld)
                [[ -z "$_macfan_package" ]] || die 'Duplicate macfanctld package archive'
                _macfan_package="$_artifact"
                _macfan_version="$CALA_PACKAGE_VERSION"
                ;;
            macpro61-support)
                [[ -z "$_support_package" ]] || die 'Duplicate macpro61-support package archive'
                _support_package="$_artifact"
                _support_version="$CALA_PACKAGE_VERSION"
                ;;
            *)
                die 'Unexpected package name in [%s]: [%s]' "$_artifact_name" "$CALA_PACKAGE_NAME"
                ;;
        esac
    done
    [[ -n "$_kernel_package" && -n "$_headers_package" && -n "$_macfan_package" && -n "$_support_package" ]] || \
        die 'Local repository does not contain the required package quartet'
    [[ "$_kernel_version" == "$_headers_version" ]] || \
        die 'Kernel/header versions do not match: [%s] versus [%s]' "$_kernel_version" "$_headers_version"

    # Catch unowned files in the profile before pacman sees the local package
    # quartet.  Directory entries are harmless; regular files and symlinks are
    # the ownership collisions that make pacman abort the installation.
    for _artifact in "${_package_files[@]}"; do
        if ! _package_paths=$(pacman -Qlp -- "$_artifact" 2>/dev/null); then
            die 'Cannot list files in package archive: [%s]' "$_artifact"
        fi
        while read -r _package_name _package_path; do
            [[ "$_package_path" == /* && "$_package_path" != */ ]] || continue
            if [[ -e "$_staged_root$_package_path" || -L "$_staged_root$_package_path" ]]; then
                die 'Package [%s] collides with a pre-created airootfs path: [%s]' \
                    "${_artifact##*/}" "$_package_path"
            fi
        done <<< "$_package_paths"
    done

    _netinstall_files=(
        "$_netinstall_source_dir/netinstall.conf"
        "$_netinstall_source_dir/netinstall.yaml"
    )
    for _artifact in "${_netinstall_files[@]}"; do
        [[ -f "$_artifact" && ! -L "$_artifact" ]] || die 'Staged Calamares source is missing: [%s]' "$_artifact"
        reject_unresolved_calamares_tokens "$_artifact"
    done
    for _artifact in \
        "$_module_dir/netinstall.conf" \
        "$_module_dir/netinstall.yaml"; do
        [[ ! -e "$_artifact" && ! -L "$_artifact" ]] || \
            die 'Package-owned Calamares path is pre-created in airootfs: [%s]' "$_artifact"
    done

    rm -rf -- "$_bundle_dir"
    mkdir -p -- "$_bundle_dir"
    for _artifact in "$_kernel_package" "$_headers_package" "$_macfan_package" "$_support_package"; do
        _artifact_name=${_artifact##*/}
        cp -- "$_artifact" "$_bundle_dir/$_artifact_name"
        _staged_packages+=("$_artifact_name")
        _staged_package_paths+=("$_bundle_dir/$_artifact_name")
    done
    (
        cd "$_bundle_dir"
        sha256sum -- "${_staged_packages[@]}" > packages.sha256
    )
    chmod 0444 -- "${_staged_package_paths[@]}" "$_bundle_dir/packages.sha256"
    chmod 0555 -- "$_bundle_dir"

    (cd "$_bundle_dir" && sha256sum -c -- packages.sha256 >/dev/null) || \
        die 'Staged package checksum manifest validation failed'
    shopt -s nullglob
    _staged_packages=("$_bundle_dir"/*.pkg.tar.zst "$_bundle_dir"/*.pkg.tar.xz)
    shopt -u nullglob
    (( ${#_staged_packages[@]} == 4 )) || die 'Staged bundle contains an unexpected package archive'

    _module_files=(
        "$_module_dir/packages-offline-macpro.conf"
        "$_module_dir/shellprocess-stage-macpro.conf"
        "$_module_dir/shellprocess-verify-macpro.conf"
        "$_module_dir/shellprocess-finalize-macpro.conf"
        "$_module_dir/macpro-layout-check.conf"
        "$_module_dir/shellprocess-enable-macpro.conf"
    )
    for _artifact in "${_module_files[@]}"; do
        [[ -f "$_artifact" && ! -L "$_artifact" ]] || die 'Staged Calamares module is missing: [%s]' "$_artifact"
    done

    render_calamares_token "${_module_files[0]}" '@@KERNEL_PACKAGE@@' "${_kernel_package##*/}"
    render_calamares_token "${_module_files[0]}" '@@HEADERS_PACKAGE@@' "${_headers_package##*/}"
    render_calamares_token "${_module_files[0]}" '@@MACFANCTLD_PACKAGE@@' "${_macfan_package##*/}"
    render_calamares_token "${_module_files[0]}" '@@SUPPORT_PACKAGE@@' "${_support_package##*/}"
    render_calamares_token "${_module_files[2]}" '@@KERNEL_VERSION@@' "$_kernel_version"
    render_calamares_token "${_module_files[2]}" '@@HEADERS_VERSION@@' "$_headers_version"
    render_calamares_token "${_module_files[2]}" '@@MACFANCTLD_VERSION@@' "$_macfan_version"
    render_calamares_token "${_module_files[2]}" '@@SUPPORT_VERSION@@' "$_support_version"
    render_calamares_token "${_module_files[3]}" '@@KERNEL_PACKAGE@@' "${_kernel_package##*/}"
    reject_unresolved_calamares_tokens "${_module_files[0]}"
    reject_unresolved_calamares_tokens "${_module_files[1]}"
    reject_unresolved_calamares_tokens "${_module_files[2]}"
    reject_unresolved_calamares_tokens "${_module_files[3]}"
    reject_unresolved_calamares_tokens "${_module_files[4]}"
    reject_unresolved_calamares_tokens "${_module_files[5]}"
    (( $(literal_token_count "${_module_files[1]}" '${ROOT}') == 1 )) || \
        die 'The staged package helper must preserve exactly one ${ROOT} token'
)

run_build() {
    prepare_profile "$1"
    local _profile="$1" _remove_status

    msg "Prepare [work: ${work_dir}, out: ${outFolder}]"

    if $clean_first; then
        msg2 "Deleting the build folder if one exists - takes some time"
        umount_fs
        sudo rm -rf -- "$work_dir"
        _remove_status=$?
        (( _remove_status == 0 )) || die "Unable to remove build work directory: [%s]" "$work_dir"
        if [[ -e "$work_dir" || -L "$work_dir" ]]; then
            die "Build work directory still exists after removal: [%s]" "$work_dir"
        fi
    fi

    msg2 "Copying the Archiso folder to build work"
    mkdir -p -- "$work_dir"
    if [[ -e "$work_dir/archiso" || -L "$work_dir/archiso" ]]; then
        die "Refusing to merge into existing staged Archiso profile: [%s]" "$work_dir/archiso"
    fi
    cp -r -- archiso "$work_dir/archiso"

    local _repo_path="$(realpath "${src_dir}/local-repo")"
    local _repo_server="file://${_repo_path}"
    local _escaped_repo_server="${_repo_server//\\/\\\\}"
    _escaped_repo_server="${_escaped_repo_server//&/\\&}"
    _escaped_repo_server="${_escaped_repo_server//|/\\|}"
    if ! grep -q '^[[:space:]]*Server = file://.*local-repo[[:space:]]*$' "${work_dir}/archiso/pacman.conf"; then
        die "Staged pacman.conf has no local-repo server entry"
    fi
    sed -i "s|^[[:space:]]*Server = file://.*local-repo[[:space:]]*$|Server = ${_escaped_repo_server}|" "${work_dir}/archiso/pacman.conf"
    if ! grep -Fqx "Server = ${_repo_server}" "${work_dir}/archiso/pacman.conf"; then
        die "Failed to set the staged local-repo server to [%s]" "$_repo_server"
    fi

    stage_calamares_bundle

    local _mkarchiso="${work_dir}/mkarchiso"
    # Tests may point this at a harmless failing executable without touching
    # the host mkarchiso or starting an ISO build.
    local _mkarchiso_source="${MKARCHISO_SOURCE:-/usr/bin/mkarchiso}"
    msg2 "Copying mkarchiso into build work"
    if [[ ! -r $_mkarchiso_source ]]; then
        die "Host mkarchiso is missing or unreadable: [%s]" "$_mkarchiso_source"
    fi
    cp -- "$_mkarchiso_source" "$_mkarchiso"
    chmod +x "$_mkarchiso"
    if $verbose; then
        msg2 "Making the staged mkarchiso verbose"
        sed -i 's/quiet="y"/quiet="n"/g' "$_mkarchiso"
    fi

    msg "Start [Build ISO]"

    # insert removal of archlinux keyrings timer on the ISO before pack
    modify_mkarchiso "$_mkarchiso"

    local _output_dir="$outFolder/$_profile" _iso_candidate _iso_stem
    local _mkarchiso_status
    local -a _preexisting_iso_artifacts=()
    mkdir -p -- "$_output_dir"
    shopt -s nullglob
    for _iso_candidate in "$_output_dir"/*.iso; do
        [[ -f "$_iso_candidate" ]] && _preexisting_iso_artifacts+=("$_iso_candidate")
    done
    shopt -u nullglob
    if (( ${#_preexisting_iso_artifacts[@]} != 0 )); then
        die "Refusing to reuse preexisting ISO artifact in [%s]: [%s]" \
            "$_output_dir" "${_preexisting_iso_artifacts[*]}"
    fi

    # Keep pacman's package cache isolated to this build.  In particular, do
    # not let fakeroot pacman -Udd reuse or modify the host cache.
    local _pacman_cache_dir
    _pacman_cache_dir=$(mktemp -d --tmpdir="$work_dir" pacman-cache.XXXXXX)
    chmod 0775 -- "$_pacman_cache_dir"
    if [[ ! -d "$_pacman_cache_dir" || ! -w "$_pacman_cache_dir" ]]; then
        die "Build-specific pacman cache is missing or not writable: [%s]" "$_pacman_cache_dir"
    fi
    local _pacman_conf="${work_dir}/archiso/pacman.conf"
    sed -i '/^[[:space:]]*CacheDir[[:space:]]*=.*/d' "$_pacman_conf"
    sed -i "/^[[:space:]]*\[options\][[:space:]]*$/a CacheDir = $_pacman_cache_dir" "$_pacman_conf"
    if ! grep -Fqx "CacheDir = $_pacman_cache_dir" "${work_dir}/archiso/pacman.conf"; then
        die "Failed to configure the staged pacman cache directory"
    fi

    cd "${work_dir}/archiso/"
    if sudo "$_mkarchiso" -v -w "$work_dir" -o "$_output_dir" "${work_dir}/archiso/"; then
        :
    else
        _mkarchiso_status=$?
        error "mkarchiso failed with status [%s]; refusing to finalize output" "$_mkarchiso_status"
        return "$_mkarchiso_status"
    fi
    sudo chown $USER $outFolder

    local -a _iso_artifacts=()
    shopt -s nullglob
    for _iso_candidate in "$_output_dir"/*.iso; do
        [[ -f "$_iso_candidate" ]] && _iso_artifacts+=("$_iso_candidate")
    done
    shopt -u nullglob
    if (( ${#_iso_artifacts[@]} == 0 )); then
        die "Expected exactly one ISO artifact in [%s], found none" "$_output_dir"
    fi
    if (( ${#_iso_artifacts[@]} > 1 )); then
        die "Expected exactly one ISO artifact in [%s], found [%s]" "$_output_dir" "${#_iso_artifacts[@]}"
    fi

    iso_file=${_iso_artifacts[0]##*/}
    _iso_stem=${iso_file%.iso}
    cp ${work_dir}/iso/arch/pkglist.x86_64.txt "$_output_dir/${_iso_stem}.pkgs.txt"

    msg "Done [Build ISO] ${iso_file}"
    msg "Finished building [%s]" "${_profile}"

    cd "$_output_dir"
    if [[ ! -e $iso_file.sha256 ]]; then
        create_chksums "$iso_file"
    elif [[ $iso_file -nt $iso_file.sha256 ]]; then
        create_chksums "$iso_file"
    else
        info "checksums for [$iso_file] already created"
    fi
    if (( EUID == 0 )); then
        warning "ISO [%s] is unsigned; sign it later with the intended non-root key owner." "$iso_file"
    elif [[ ! -e $iso_file.sig ]]; then
        sign_with_key "$iso_file"
    elif [[ $iso_file -nt $iso_file.sig ]]; then
        rm $iso_file.sig
        sign_with_key "$iso_file"
    else
        info "signature file for [$iso_file] already created"
    fi
    show_elapsed_time "${FUNCNAME}" "${timer_start}"
    if [[ "$build_in_ram" == "true" && "$remove_build_dir" == "false" ]]; then
        msg "!!! Remember to remove $work_dir !!!"
        msg2 "sudo rm -rf $work_dir"
    fi
    if [[ "$remove_build_dir" == "true" ]]; then
        msg "Automatically removing build directory ($work_dir)..."
        umount_fs
        [ -d ${work_dir} ] && sudo rm -rf ${work_dir}
        msg2 "Removed"
    fi
}

gen_iso_fn(){
    local vars=() name
    vars+=("cachyos")
    [[ -n ${profile} ]] && vars+=("${profile}")

    vars+=("linux")
    vars+=("$(date +%y%m%d)")

    for n in ${vars[@]}; do
        name=${name:-}${name:+-}${n}
    done

    echo $name
}
