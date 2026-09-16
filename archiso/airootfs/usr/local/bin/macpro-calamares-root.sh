#!/bin/bash
set -euo pipefail

source /usr/local/lib/macpro-package-bundle.sh

BUNDLE_DIR=/opt/macpro-packages
MANIFEST="$BUNDLE_DIR/packages.sha256"
SETTINGS_SOURCE=/usr/share/calamares/settings_online.conf
SETTINGS_TARGET=/etc/calamares/settings.conf
NETINSTALL_CONFIG=/etc/calamares/modules/netinstall.yaml
NETINSTALL_MODULE_CONFIG=/etc/calamares/modules/netinstall.conf
NETINSTALL_SOURCE_DIR=/usr/local/share/macpro-calamares
NETINSTALL_SOURCE=${NETINSTALL_SOURCE_DIR}/netinstall.yaml
NETINSTALL_MODULE_SOURCE=${NETINSTALL_SOURCE_DIR}/netinstall.conf
SETTINGS_TMP=''
OVERLAY_TMP=''
NETINSTALL_TMP=''

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || fail 'The Calamares root helper must run as root.'
(( $# == 0 )) || fail 'The Calamares root helper does not accept arguments.'
macpro_validate_bundle "$BUNDLE_DIR" "$MANIFEST"

[[ -f "$SETTINGS_SOURCE" && ! -L "$SETTINGS_SOURCE" ]] || fail "Packaged settings are missing: $SETTINGS_SOURCE"
[[ -d "$NETINSTALL_SOURCE_DIR" && ! -L "$NETINSTALL_SOURCE_DIR" ]] || \
    fail "Vetted Calamares source directory is missing: $NETINSTALL_SOURCE_DIR"
[[ -f "$NETINSTALL_SOURCE" && ! -L "$NETINSTALL_SOURCE" ]] || fail "Vetted netinstall source is missing: $NETINSTALL_SOURCE"
[[ -f "$NETINSTALL_MODULE_SOURCE" && ! -L "$NETINSTALL_MODULE_SOURCE" ]] || \
    fail "Vetted netinstall module source is missing: $NETINSTALL_MODULE_SOURCE"
[[ "$NETINSTALL_CONFIG" == /etc/calamares/modules/netinstall.yaml ]] || fail 'Unexpected Calamares netinstall override path.'
[[ "$NETINSTALL_MODULE_CONFIG" == /etc/calamares/modules/netinstall.conf ]] || fail 'Unexpected Calamares netinstall module config path.'
mkdir -p /etc/calamares/modules
cleanup() {
    [[ -z "$SETTINGS_TMP" ]] || rm -f -- "$SETTINGS_TMP"
    [[ -z "$OVERLAY_TMP" ]] || rm -f -- "$OVERLAY_TMP"
    [[ -z "$NETINSTALL_TMP" ]] || rm -f -- "$NETINSTALL_TMP"
}
trap cleanup EXIT

install_netinstall_source() {
    local source="$1" target="$2"
    NETINSTALL_TMP=$(mktemp "${target}.XXXXXX")
    cp -- "$source" "$NETINSTALL_TMP"
    chmod 0644 -- "$NETINSTALL_TMP"
    mv -- "$NETINSTALL_TMP" "$target"
    NETINSTALL_TMP=''
}

install_netinstall_source "$NETINSTALL_MODULE_SOURCE" "$NETINSTALL_MODULE_CONFIG"
install_netinstall_source "$NETINSTALL_SOURCE" "$NETINSTALL_CONFIG"

[[ -f "$NETINSTALL_CONFIG" && ! -L "$NETINSTALL_CONFIG" ]] || fail "Safe Calamares netinstall override is missing: $NETINSTALL_CONFIG"
[[ -f "$NETINSTALL_MODULE_CONFIG" && ! -L "$NETINSTALL_MODULE_CONFIG" ]] || \
    fail "Safe Calamares netinstall module config is missing: $NETINSTALL_MODULE_CONFIG"
! grep -Fq -- 'linux-cachyos' "$NETINSTALL_CONFIG" || fail "Unsafe stock kernel package found in $NETINSTALL_CONFIG"
[[ $(grep -Ec '^[[:space:]]*groupsUrl:[[:space:]]*$' "$NETINSTALL_MODULE_CONFIG") == 1 ]] || \
    fail 'The netinstall override must contain exactly one groupsUrl source list.'
[[ $(awk '
    {
        if ($0 ~ /^groupsUrl:[[:space:]]*$/) {
            in_groups=1
            groups++
            next
        }
        if (in_groups && $0 ~ /^[^[:space:]#-][^:]*:[[:space:]]*/) in_groups=0
        if (in_groups && $0 ~ /^[[:space:]]*-[[:space:]]+/) entries++
    }
    END { print groups + 0, entries + 0 }
' "$NETINSTALL_MODULE_CONFIG") == '1 1' ]] || \
    fail 'The netinstall override must contain only one groups source entry.'
[[ $(grep -Ec '^[[:space:]]*-[[:space:]]+file:///etc/calamares/modules/netinstall\.yaml[[:space:]]*$' "$NETINSTALL_MODULE_CONFIG") == 1 ]] || \
    fail 'The netinstall override must contain exactly one vetted local groups source.'
! grep -Eiq -- '(^|[^[:alnum:]_])(https?|ftp)://|(^|[[:space:]])(url|source)[[:space:]]*:' "$NETINSTALL_MODULE_CONFIG" || \
    fail 'Remote URL/source configuration found in the netinstall override.'

module_configs=(
    /etc/calamares/modules/macpro-layout-check.conf
    /etc/calamares/modules/shellprocess-stage-macpro.conf
    /etc/calamares/modules/packages-offline-macpro.conf
    /etc/calamares/modules/shellprocess-verify-macpro.conf
    /etc/calamares/modules/shellprocess-enable-macpro.conf
    /etc/calamares/modules/shellprocess-finalize-macpro.conf
    "$NETINSTALL_MODULE_CONFIG"
    "$NETINSTALL_CONFIG"
)
for config in "${module_configs[@]}"; do
    [[ -f "$config" && ! -L "$config" ]] || fail "Calamares module config is missing: $config"
done

# Python job module implementation. Calamares loads job modules from its
# module search path (/usr/lib/calamares/modules), never from /etc — check
# here so a misplaced module fails with a clear error instead of the
# loader's "not found in module search paths" dialog.
for module_file in \
    /usr/lib/calamares/modules/macpro-layout-check/module.desc \
    /usr/lib/calamares/modules/macpro-layout-check/main.py; do
    [[ -f "$module_file" && ! -L "$module_file" ]] || fail "Calamares python module file is missing: $module_file"
done

SETTINGS_TMP=$(mktemp /etc/calamares/.settings.conf.XXXXXX)
cp -- "$SETTINGS_SOURCE" "$SETTINGS_TMP"

exec_sequence_line() {
    local file="$1" token="$2"
    awk -v token="$token" '
        function trim(value) {
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            return value
        }
        function indentation(value) {
            match(value, /^[[:space:]]*/)
            return RLENGTH
        }
        {
            raw=$0
            line=trim(raw)
            if (raw ~ /^sequence:[[:space:]]*$/) {
                in_sequence=1
                in_exec=0
                sequence_indent=-1
                next
            }
            if (in_sequence && raw ~ /^[^[:space:]#-][^:]*:[[:space:]]*/) {
                in_sequence=0
                in_exec=0
                next
            }
            if (in_sequence && !in_exec && raw ~ /^[[:space:]]*-[[:space:]]+/) {
                item_indent=indentation(raw)
                if (sequence_indent < 0) sequence_indent=item_indent
                if (item_indent == sequence_indent && raw ~ /^[[:space:]]*-[[:space:]]+exec:[[:space:]]*$/) {
                    in_exec=1
                    exec_indent=item_indent
                }
                next
            }
            if (in_exec && indentation(raw) <= exec_indent && raw ~ /^[[:space:]]*-[[:space:]]+/) {
                in_exec=0
            }
            if (in_exec && indentation(raw) > exec_indent && line == "- " token) print NR
        }
    ' "$file"
}
exec_sequence_count() {
    exec_sequence_line "$1" "$2" | awk 'END { print NR + 0 }'
}
exec_section_count() {
    awk '
        function indentation(value) {
            match(value, /^[[:space:]]*/)
            return RLENGTH
        }
        {
            if ($0 ~ /^sequence:[[:space:]]*$/) {
                in_sequence=1
                sequence_indent=-1
            }
            else if (in_sequence && $0 ~ /^[^[:space:]#-][^:]*:[[:space:]]*/) in_sequence=0
            else if (in_sequence && $0 ~ /^[[:space:]]*-[[:space:]]+/) {
                item_indent=indentation($0)
                if (sequence_indent < 0) sequence_indent=item_indent
                if (item_indent == sequence_indent && $0 ~ /^[[:space:]]*-[[:space:]]+exec:[[:space:]]*$/) count++
            }
        }
        END { print count + 0 }
    ' "$1"
}
require_one_exec_anchor() {
    local file="$1" token="$2" count="$3"
    (( count == 1 )) || fail "Expected exactly one exec anchor - $token; found $count"
}

literal_token_count() {
    local file="$1" token="$2"
    awk -v needle="$token" '
        {
            rest=$0
            while ((position=index(rest, needle)) != 0) {
                count++
                rest=substr(rest, position + length(needle))
            }
        }
        END { print count + 0 }
    ' "$file"
}

exact_line_count() {
    local file="$1" wanted="$2"
    awk -v wanted="$wanted" '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            if (line == wanted) count++
        }
        END { print count + 0 }
    ' "$file"
}

exact_line_number() {
    local file="$1" wanted="$2"
    awk -v wanted="$wanted" '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            if (line == wanted) print NR
        }
    ' "$file"
}

instance_id_count() {
    local file="$1" wanted_id="$2"
    awk -v wanted_id="$wanted_id" '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            if (line ~ /^- id[[:space:]]*:/) {
                sub(/^- id[[:space:]]*:[[:space:]]*/, "", line)
                if (line == wanted_id) count++
            }
        }
        END { print count + 0 }
    ' "$file"
}

instance_id_line_number() {
    local file="$1" wanted_id="$2"
    awk -v wanted_id="$wanted_id" '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            if (line ~ /^- id[[:space:]]*:/) {
                value=line
                sub(/^- id[[:space:]]*:[[:space:]]*/, "", value)
                if (value == wanted_id) print NR
            }
        }
    ' "$file"
}

instance_block_count() {
    local file="$1" wanted_id="$2" wanted_module="$3" wanted_config="$4"
    awk -v wanted_id="$wanted_id" -v wanted_module="$wanted_module" -v wanted_config="$wanted_config" '
        function yaml_field(line, field, value, prefix) {
            value=line
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            if (field == "id") prefix="^- id[[:space:]]*:[[:space:]]*"
            else prefix="^[[:space:]]*" field "[[:space:]]*:[[:space:]]*"
            if (value !~ prefix) return ""
            sub(prefix, "", value)
            sub(/[[:space:]]*$/, "", value)
            return value
        }
        function flush(    i) {
            if (in_block && block_count >= 3 &&
                yaml_field(block[1], "id") == wanted_id &&
                yaml_field(block[2], "module") == wanted_module &&
                (wanted_config == "" || yaml_field(block[3], "config") == wanted_config)) count++
            for (i=1; i<=block_count; i++) delete block[i]
            in_block=0
            block_count=0
        }
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            if (line ~ /^- id[[:space:]]*:/) {
                flush()
                in_block=1
                block_count=1
                block[1]=line
                next
            }
            if (in_block) block[++block_count]=line
        }
        END { flush(); print count + 0 }
    ' "$file"
}

remove_exact_exec_entry() {
    local file="$1" token="$2" output="$3"
    awk -v wanted="- $token" '
        function trim(value) {
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            return value
        }
        function indentation(value) {
            match(value, /^[[:space:]]*/)
            return RLENGTH
        }
        {
            raw=$0
            line=trim(raw)
            if (raw ~ /^sequence:[[:space:]]*$/) {
                in_sequence=1
                in_exec=0
                sequence_indent=-1
                print raw
                next
            }
            if (in_sequence && raw ~ /^[^[:space:]#-][^:]*:[[:space:]]*/) {
                in_sequence=0
                in_exec=0
            }
            if (in_sequence && !in_exec && raw ~ /^[[:space:]]*-[[:space:]]+/) {
                item_indent=indentation(raw)
                if (sequence_indent < 0) sequence_indent=item_indent
                if (item_indent == sequence_indent && raw ~ /^[[:space:]]*-[[:space:]]+exec:[[:space:]]*$/) {
                    in_exec=1
                    exec_indent=item_indent
                }
            } else if (in_exec && indentation(raw) <= exec_indent && raw ~ /^[[:space:]]*-[[:space:]]+/) {
                in_exec=0
            }
            if (in_exec && indentation(raw) > exec_indent && line == wanted) {
                removed++
                next
            }
            print raw
        }
        END { exit (removed == 1 ? 0 : 1) }
    ' "$file" > "$output" || fail "Expected exactly one exec entry - $token"
    mv -- "$output" "$file"
}

insert_macpro_instances() {
    local file="$1" output="$2"
    awk '
        {
            line=$0
            if (line ~ /^sequence:[[:space:]]*$/) {
                print "- id: macpro-layout-check"
                print "  module: macpro-layout-check"
                print "  config: macpro-layout-check.conf"
                print "- id: stage-macpro"
                print "  module: shellprocess"
                print "  config: shellprocess-stage-macpro.conf"
                print "- id: offline-macpro"
                print "  module: packages"
                print "  config: packages-offline-macpro.conf"
                print "- id: verify-macpro"
                print "  module: shellprocess"
                print "  config: shellprocess-verify-macpro.conf"
                print "- id: enable-macpro"
                print "  module: shellprocess"
                print "  config: shellprocess-enable-macpro.conf"
                print "- id: finalize-macpro"
                print "  module: shellprocess"
                print "  config: shellprocess-finalize-macpro.conf"
                inserted++
            }
            print line
        }
        END { exit (inserted == 1 ? 0 : 1) }
    ' "$file" > "$output" || fail 'Expected exactly one sequence section in Calamares settings'
    mv -- "$output" "$file"
}

insert_macpro_sequence() {
    local file="$1" output="$2"
    awk '
        function trim(value) {
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            return value
        }
        function indentation(value) {
            match(value, /^[[:space:]]*/)
            return RLENGTH
        }
        {
            line=$0
            trimmed=trim(line)
            if (line ~ /^sequence:[[:space:]]*$/) {
                in_sequence=1
                in_exec=0
                print line
                next
            }
            if (in_sequence && line ~ /^[^[:space:]#-][^:]*:[[:space:]]*/) {
                in_sequence=0
                in_exec=0
            }
            if (in_sequence && !in_exec && line ~ /^[[:space:]]*-[[:space:]]+exec:[[:space:]]*$/) {
                in_exec=1
                exec_indent=indentation(line)
                print line
                next
            }
            if (in_exec && indentation(line) <= exec_indent && line ~ /^[[:space:]]*-[[:space:]]+/) {
                in_exec=0
            }
            if (in_exec && indentation(line) > exec_indent && trimmed == "- partition") {
                prefix=substr(line, 1, length(line) - length(trimmed))
                print line
                print prefix "- macpro-layout-check"
                layout_inserted++
                next
            }
            if (in_exec && indentation(line) > exec_indent && trimmed == "- packages@online") {
                prefix=substr(line, 1, length(line) - length(trimmed))
                print line
                print prefix "- shellprocess@stage-macpro"
                print prefix "- packages@offline-macpro"
                print prefix "- shellprocess@verify-macpro"
                print prefix "- shellprocess@enable-macpro"
                packages_inserted++
                next
            }
            if (in_exec && indentation(line) > exec_indent && trimmed == "- initcpio") {
                prefix=substr(line, 1, length(line) - length(trimmed))
                print line
                print prefix "- shellprocess@finalize-macpro"
                finalize_inserted++
                next
            }
            print line
        }
        END { exit (layout_inserted == 1 && packages_inserted == 1 && finalize_inserted == 1 ? 0 : 1) }
    ' "$file" > "$output" || fail 'Expected exactly one nested exec insertion point for each Mac Pro job group'
    mv -- "$output" "$file"
}

for config in "${module_configs[@]}"; do
    if grep -Eq '@@(KERNEL_PACKAGE|HEADERS_PACKAGE|MACFANCTLD_PACKAGE|SUPPORT_PACKAGE|KERNEL_VERSION|HEADERS_VERSION|MACFANCTLD_VERSION|SUPPORT_VERSION)@@' "$config"; then
        fail "Unresolved template token remains in $config"
    fi
done
[[ $(literal_token_count "${module_configs[1]}" '${ROOT}') == 1 ]] || fail 'The stage config must contain exactly one ${ROOT} token.'
[[ $(literal_token_count "${module_configs[2]}" '${ROOT}') == 0 ]] || fail 'The offline package config contains a ROOT token.'
[[ $(literal_token_count "${module_configs[3]}" '${ROOT}') == 0 ]] || fail 'The verify config contains a ROOT token.'
[[ $(literal_token_count "${module_configs[4]}" '${ROOT}') == 0 ]] || fail 'The enable config contains a ROOT token.'
[[ $(literal_token_count "${module_configs[5]}" '${ROOT}') == 0 ]] || fail 'The finalize config contains a ROOT token.'
[[ $(exact_line_count "${module_configs[4]}" 'dontChroot: false') == 1 ]] || fail 'The enable config must use target chroot execution.'
[[ $(exact_line_count "${module_configs[4]}" '- command: "/usr/bin/systemctl enable macfanctld.service"') == 1 ]] || \
    fail 'The enable config must run the exact macfanctld service command.'
[[ $(exact_line_count "${module_configs[5]}" 'dontChroot: false') == 1 ]] || fail 'The finalize config must use target chroot execution.'
[[ $(grep -Ec '^[[:space:]]*- command: "/usr/lib/macpro61-support/macpro61-bootctl seed-rollback /var/cache/calamares/packages/[^"@[:space:]]+"$' "${module_configs[5]}") == 1 ]] || \
    fail 'The finalize config must seed rollback from the rendered kernel archive.'
[[ $(exact_line_count "${module_configs[5]}" '- command: "/usr/lib/macpro61-support/macpro61-bootctl finalize"') == 1 ]] || \
    fail 'The finalize config must run the exact macpro61 boot finalizer command.'

[[ $(exact_line_count "$SETTINGS_TMP" 'instances:') == 1 ]] || fail 'Calamares settings must contain exactly one instances: section.'
[[ $(exact_line_count "$SETTINGS_TMP" 'sequence:') == 1 ]] || fail 'Calamares settings must contain exactly one sequence: section.'
instances_section_line=$(exact_line_number "$SETTINGS_TMP" 'instances:')
sequence_section_line=$(exact_line_number "$SETTINGS_TMP" 'sequence:')
(( instances_section_line < sequence_section_line )) || fail 'Calamares instances: must precede sequence:.'

[[ $(exec_section_count "$SETTINGS_TMP") == 1 ]] || fail 'Calamares settings must contain exactly one nested exec: list.'
for anchor in partition packages@online initcpiocfg initcpio; do
    require_one_exec_anchor "$SETTINGS_TMP" "$anchor" "$(exec_sequence_count "$SETTINGS_TMP" "$anchor")"
done
require_one_exec_anchor "$SETTINGS_TMP" shellprocess "$(exec_sequence_count "$SETTINGS_TMP" shellprocess)"
require_one_exec_anchor "$SETTINGS_TMP" grubcfg "$(exec_sequence_count "$SETTINGS_TMP" grubcfg)"
require_one_exec_anchor "$SETTINGS_TMP" bootloader "$(exec_sequence_count "$SETTINGS_TMP" bootloader)"
partition_line=$(exec_sequence_line "$SETTINGS_TMP" partition)
packages_line=$(exec_sequence_line "$SETTINGS_TMP" packages@online)
initcpiocfg_line=$(exec_sequence_line "$SETTINGS_TMP" initcpiocfg)
initcpio_line=$(exec_sequence_line "$SETTINGS_TMP" initcpio)
(( partition_line < packages_line && packages_line < initcpiocfg_line && initcpiocfg_line < initcpio_line )) || \
    fail 'Calamares exec anchors are out of order.'

for id in macpro-layout-check stage-macpro offline-macpro verify-macpro enable-macpro finalize-macpro; do
    (( $(instance_id_count "$SETTINGS_TMP" "$id") == 0 )) || fail "Duplicate Mac Pro instance id already exists: $id"
done
for job in macpro-layout-check shellprocess@stage-macpro packages@offline-macpro shellprocess@verify-macpro shellprocess@enable-macpro shellprocess@finalize-macpro; do
    (( $(exec_sequence_count "$SETTINGS_TMP" "$job") == 0 )) || fail "Duplicate Mac Pro exec job already exists: $job"
done

OVERLAY_TMP=$(mktemp /etc/calamares/.settings.overlay.XXXXXX)
remove_exact_exec_entry "$SETTINGS_TMP" bootloader "$OVERLAY_TMP"
remove_exact_exec_entry "$SETTINGS_TMP" shellprocess "$OVERLAY_TMP"
remove_exact_exec_entry "$SETTINGS_TMP" grubcfg "$OVERLAY_TMP"
insert_macpro_instances "$SETTINGS_TMP" "$OVERLAY_TMP"
insert_macpro_sequence "$SETTINGS_TMP" "$OVERLAY_TMP"
OVERLAY_TMP=''

[[ $(exact_line_count "$SETTINGS_TMP" 'instances:') == 1 ]] || fail 'instances: count changed during Calamares overlay.'
[[ $(exact_line_count "$SETTINGS_TMP" 'sequence:') == 1 ]] || fail 'sequence: count changed during Calamares overlay.'
[[ $(exec_sequence_count "$SETTINGS_TMP" shellprocess) == 0 ]] || fail 'The bare generic shellprocess writer remains in the exec list.'
[[ $(exec_sequence_count "$SETTINGS_TMP" grubcfg) == 0 ]] || fail 'grubcfg was not removed from the exec list.'
[[ $(exec_sequence_count "$SETTINGS_TMP" bootloader) == 0 ]] || fail 'bootloader was not removed from the exec list.'
[[ $(exec_sequence_count "$SETTINGS_TMP" macpro-layout-check) == 1 ]] || fail 'Layout-check job count is not exactly one.'
[[ $(exec_sequence_count "$SETTINGS_TMP" packages@online) == 1 ]] || fail 'packages@online count changed during overlay.'
[[ $(exec_sequence_count "$SETTINGS_TMP" initcpiocfg) == 1 ]] || fail 'initcpiocfg count changed during overlay.'
[[ $(exec_sequence_count "$SETTINGS_TMP" initcpio) == 1 ]] || fail 'initcpio count changed during overlay.'
[[ $(exec_sequence_count "$SETTINGS_TMP" shellprocess@stage-macpro) == 1 ]] || fail 'Stage job count is not exactly one.'
[[ $(exec_sequence_count "$SETTINGS_TMP" packages@offline-macpro) == 1 ]] || fail 'Offline package job count is not exactly one.'
[[ $(exec_sequence_count "$SETTINGS_TMP" shellprocess@verify-macpro) == 1 ]] || fail 'Verify job count is not exactly one.'
[[ $(exec_sequence_count "$SETTINGS_TMP" shellprocess@enable-macpro) == 1 ]] || fail 'Enable job count is not exactly one.'
[[ $(exec_sequence_count "$SETTINGS_TMP" shellprocess@finalize-macpro) == 1 ]] || fail 'Finalize job count is not exactly one.'

for spec in \
    'macpro-layout-check|macpro-layout-check|macpro-layout-check.conf' \
    'stage-macpro|shellprocess|shellprocess-stage-macpro.conf' \
    'offline-macpro|packages|packages-offline-macpro.conf' \
    'verify-macpro|shellprocess|shellprocess-verify-macpro.conf' \
    'enable-macpro|shellprocess|shellprocess-enable-macpro.conf' \
    'finalize-macpro|shellprocess|shellprocess-finalize-macpro.conf'; do
    IFS='|' read -r id module config <<< "$spec"
    [[ $(instance_id_count "$SETTINGS_TMP" "$id") == 1 ]] || fail "Instance id count is not exactly one: $id"
    [[ $(instance_block_count "$SETTINGS_TMP" "$id" "$module" "$config") == 1 ]] || \
        fail "Instance definition is not exact or unique: $id"
    instance_line=$(instance_id_line_number "$SETTINGS_TMP" "$id")
    case "$id" in
        macpro-layout-check) sequence_use_line=$(exec_sequence_line "$SETTINGS_TMP" macpro-layout-check) ;;
        stage-macpro) sequence_use_line=$(exec_sequence_line "$SETTINGS_TMP" shellprocess@stage-macpro) ;;
        offline-macpro) sequence_use_line=$(exec_sequence_line "$SETTINGS_TMP" packages@offline-macpro) ;;
        verify-macpro) sequence_use_line=$(exec_sequence_line "$SETTINGS_TMP" shellprocess@verify-macpro) ;;
        enable-macpro) sequence_use_line=$(exec_sequence_line "$SETTINGS_TMP" shellprocess@enable-macpro) ;;
        finalize-macpro) sequence_use_line=$(exec_sequence_line "$SETTINGS_TMP" shellprocess@finalize-macpro) ;;
    esac
    (( instance_line < sequence_use_line )) || fail "Instance definition follows its sequence use: $id"
done

packages_line=$(exec_sequence_line "$SETTINGS_TMP" packages@online)
partition_line=$(exec_sequence_line "$SETTINGS_TMP" partition)
layout_line=$(exec_sequence_line "$SETTINGS_TMP" macpro-layout-check)
stage_line=$(exec_sequence_line "$SETTINGS_TMP" shellprocess@stage-macpro)
offline_line=$(exec_sequence_line "$SETTINGS_TMP" packages@offline-macpro)
verify_line=$(exec_sequence_line "$SETTINGS_TMP" shellprocess@verify-macpro)
enable_line=$(exec_sequence_line "$SETTINGS_TMP" shellprocess@enable-macpro)
initcpiocfg_line=$(exec_sequence_line "$SETTINGS_TMP" initcpiocfg)
initcpio_line=$(exec_sequence_line "$SETTINGS_TMP" initcpio)
finalize_line=$(exec_sequence_line "$SETTINGS_TMP" shellprocess@finalize-macpro)
(( layout_line == partition_line + 1 )) || fail 'Layout-check job is not immediately after partition selection.'
(( layout_line < packages_line )) || fail 'Layout-check job is not before package installation.'
(( stage_line == packages_line + 1 && offline_line == packages_line + 2 && verify_line == packages_line + 3 && enable_line == packages_line + 4 )) || \
    fail 'Mac Pro jobs are not immediately after packages@online.'
(( finalize_line == initcpio_line + 1 )) || fail 'Finalize job is not immediately after initcpio.'
(( packages_line < stage_line && stage_line < offline_line && offline_line < verify_line && verify_line < enable_line && enable_line < initcpiocfg_line && initcpiocfg_line < initcpio_line && initcpio_line < finalize_line )) || \
    fail 'Final Calamares exec ordering is invalid.'

mv -- "$SETTINGS_TMP" "$SETTINGS_TARGET"
SETTINGS_TMP=''
trap - EXIT
exec calamares -D6
