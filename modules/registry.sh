#!/usr/bin/env bash
# modules/registry.sh — Module manifest for mInstaller
#
# To add a new module:
#   1. Create modules/<name>.sh implementing module_<name>_install()
#      and optionally module_<name>_preflight().
#   2. Add an entry to MINSTALLER_MODULES below.
#   3. Source the new file in this registry.
#
# Format of each registry entry (associative-array-like via naming convention):
#   MINSTALLER_MODULES   — ordered list of module IDs
#   MODULE_<ID>_NAME     — human-readable display name
#   MODULE_<ID>_DESC     — one-line description
#   MODULE_<ID>_FILE     — path to the module script (relative to MINSTALLER_ROOT)

# ---------------------------------------------------------------------------
# Clear inherited MODULE_* environment variables so callers cannot override
# registry entries via env_keep / sudo -E / exported shell variables.
# ---------------------------------------------------------------------------
while IFS= read -r _minstaller_var; do
    unset "${_minstaller_var}"
done < <(compgen -A variable | grep '^MODULE_')
unset _minstaller_var

# ---------------------------------------------------------------------------
# Module list — edit this array to register/deregister modules
# ---------------------------------------------------------------------------
MINSTALLER_MODULES=(
    mcollector
    mscreenshot
)

# ---------------------------------------------------------------------------
# Module metadata
# ---------------------------------------------------------------------------

# mcollector
MODULE_mcollector_NAME="mCollector"
MODULE_mcollector_DESC="NTLMv2 hash capture via rogue SMB2/mDNS/HTTPS server (C binary, ports 80/443/445/5353/5355)"
MODULE_mcollector_FILE="modules/mcollector.sh"

# mscreenshot
MODULE_mscreenshot_NAME="mScreenshot"
MODULE_mscreenshot_DESC="Full-port nmap scanner with headless Chromium screenshots and HTML output"
MODULE_mscreenshot_FILE="modules/mscreenshot.sh"

# ---------------------------------------------------------------------------
# registry_list_modules — print all registered module IDs and descriptions
# ---------------------------------------------------------------------------
registry_list_modules() {
    printf '\n%-16s  %s\n' "MODULE" "DESCRIPTION"
    printf '%-16s  %s\n' "------" "-----------"
    local id name desc
    for id in "${MINSTALLER_MODULES[@]}"; do
        name="MODULE_${id}_NAME"
        desc="MODULE_${id}_DESC"
        printf '%-16s  %s\n' "${id}" "${!desc:-${!name:-unknown}}"
    done
    printf '\n'
}

# ---------------------------------------------------------------------------
# registry_validate_module <id>
#   Returns 0 if <id> is a known module, 1 otherwise.
# ---------------------------------------------------------------------------
registry_validate_module() {
    local target="${1:?registry_validate_module: missing module id}"
    local id
    for id in "${MINSTALLER_MODULES[@]}"; do
        [[ "${id}" == "${target}" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# registry_source_module <id>
#   Sources the module file for <id>. Resolves path relative to MINSTALLER_ROOT.
# ---------------------------------------------------------------------------
registry_source_module() {
    local id="${1:?registry_source_module: missing module id}"
    local file_var="MODULE_${id}_FILE"
    local file="${!file_var:-}"

    if [[ -z "${file}" ]]; then
        die "registry: no file registered for module '${id}'"
    fi

    local full_path
    full_path="$(readlink -f "${MINSTALLER_ROOT}/${file}")"

    if [[ -z "${full_path}" || ! -f "${full_path}" ]]; then
        die "registry: module file not found: ${MINSTALLER_ROOT}/${file}"
    fi

    if [[ "${full_path}" != "${MINSTALLER_ROOT}/modules/"* ]]; then
        die "registry: refusing to source module outside ${MINSTALLER_ROOT}/modules: ${full_path}"
    fi

    # shellcheck disable=SC1090
    source "${full_path}"
    log_debug "Module sourced: ${id} (${full_path})"
}
