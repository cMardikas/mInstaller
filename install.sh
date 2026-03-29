#!/usr/bin/env bash
# =============================================================================
# mInstaller — Modular Kali Linux Installer Framework
# =============================================================================
#
# Usage:
#   sudo ./install.sh [OPTIONS] <module> [<module> ...]
#   sudo ./install.sh [OPTIONS] all
#
# Options:
#   -h, --help            Show this help message
#   -l, --list            List available modules
#   -n, --dry-run         Print what would be done without making changes
#   -y, --noninteractive  Assume yes to all interactive prompts
#   -v, --verbose         Enable debug logging
#   -V, --version         Print mInstaller version
#
# Examples:
#   sudo ./install.sh all
#   sudo ./install.sh mcollector
#   sudo ./install.sh mscreenshot
#   sudo ./install.sh --dry-run all
#   sudo ./install.sh --noninteractive mcollector mscreenshot
#
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script location (works whether called directly or via symlink)
# ---------------------------------------------------------------------------
MINSTALLER_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export MINSTALLER_ROOT

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
MINSTALLER_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Default global flags (exported so lib functions can read them)
# ---------------------------------------------------------------------------
export DRY_RUN=0
export NONINTERACTIVE=0
export MINSTALLER_LOG_LEVEL=2   # INFO

# ---------------------------------------------------------------------------
# Source core libraries (order matters)
# ---------------------------------------------------------------------------
# shellcheck source=lib/log.sh
source "${MINSTALLER_ROOT}/lib/log.sh"
# shellcheck source=lib/apt.sh
source "${MINSTALLER_ROOT}/lib/apt.sh"
# shellcheck source=lib/git.sh
source "${MINSTALLER_ROOT}/lib/git.sh"
# shellcheck source=lib/system.sh
source "${MINSTALLER_ROOT}/lib/system.sh"
# shellcheck source=lib/preflight.sh
source "${MINSTALLER_ROOT}/lib/preflight.sh"
# shellcheck source=modules/registry.sh
source "${MINSTALLER_ROOT}/modules/registry.sh"

# ---------------------------------------------------------------------------
# usage — print help to stdout
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
mInstaller v${MINSTALLER_VERSION} — Modular Kali Linux Installer

Usage:
  sudo $(basename "${BASH_SOURCE[0]}") [OPTIONS] <module> [<module> ...]
  sudo $(basename "${BASH_SOURCE[0]}") [OPTIONS] all

Options:
  -h, --help            Show this help message
  -l, --list            List available modules with descriptions
  -n, --dry-run         Simulate install; print what would be done (no changes)
  -y, --noninteractive  Assume 'yes' to all prompts (suitable for automation)
  -v, --verbose         Enable debug-level logging
  -V, --version         Print version and exit

Modules:
$(registry_list_modules)

Examples:
  # Install everything
  sudo ./install.sh all

  # Install only mCollector
  sudo ./install.sh mcollector

  # Dry-run both modules
  sudo ./install.sh --dry-run all

  # Automated (no prompts) install of mScreenshot
  sudo ./install.sh --noninteractive mscreenshot

EOF
}

# ---------------------------------------------------------------------------
# parse_args — populate globals from CLI
# ---------------------------------------------------------------------------
parse_args() {
    SELECTED_MODULES=()

    if [[ "$#" -eq 0 ]]; then
        usage
        exit 0
    fi

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -l|--list)
                registry_list_modules
                exit 0
                ;;
            -n|--dry-run)
                DRY_RUN=1
                export DRY_RUN
                ;;
            -y|--noninteractive)
                NONINTERACTIVE=1
                export NONINTERACTIVE
                ;;
            -v|--verbose)
                MINSTALLER_LOG_LEVEL="${LOG_LEVEL_DEBUG}"
                export MINSTALLER_LOG_LEVEL
                ;;
            -V|--version)
                printf 'mInstaller %s\n' "${MINSTALLER_VERSION}"
                exit 0
                ;;
            all)
                SELECTED_MODULES=("${MINSTALLER_MODULES[@]}")
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                # Treat as a module name
                if registry_validate_module "$1"; then
                    SELECTED_MODULES+=("$1")
                else
                    log_error "Unknown module: '$1'"
                    log_error "Run '$(basename "${BASH_SOURCE[0]}") --list' to see available modules."
                    exit 1
                fi
                ;;
        esac
        shift
    done

    if [[ "${#SELECTED_MODULES[@]}" -eq 0 ]]; then
        log_error "No modules selected."
        usage
        exit 1
    fi

    # Deduplicate preserving order
    local -A _seen=()
    local -a _dedup=()
    local m
    for m in "${SELECTED_MODULES[@]}"; do
        if [[ -z "${_seen[${m}]+_}" ]]; then
            _seen["${m}"]=1
            _dedup+=("${m}")
        fi
    done
    SELECTED_MODULES=("${_dedup[@]}")
}

# ---------------------------------------------------------------------------
# run_module <id> — source module file, run preflight then install
# ---------------------------------------------------------------------------
run_module() {
    local id="${1:?run_module: missing module id}"
    local name_var="MODULE_${id}_NAME"
    local display_name="${!name_var:-${id}}"

    log_step "=== MODULE: ${display_name} ==="

    # Source the module script
    registry_source_module "${id}"

    # Run preflight if defined
    local preflight_fn="module_${id}_preflight"
    if declare -f "${preflight_fn}" &>/dev/null; then
        "${preflight_fn}"
    else
        log_debug "No preflight function for module '${id}'"
    fi

    # Run install
    local install_fn="module_${id}_install"
    if declare -f "${install_fn}" &>/dev/null; then
        "${install_fn}"
    else
        die "Module '${id}' does not define '${install_fn}'"
    fi
}

# ---------------------------------------------------------------------------
# print_banner
# ---------------------------------------------------------------------------
print_banner() {
    cat <<EOF
  _         _   _         _        _ _
 | |       | | | |       | |      | | |
 | |__  ___| |_| |_ __ __| | ___  | | |
 | '_ \\/ __| __| ' |/ _\` |/ _ \\ / _\` |
 | | | \\__ \\ |_| | | (_| | (_) | (_| |
 |_| |_|___/\\__|_|_|\\__,_|\\___/ \\__,_|

  mInstaller — Kali Linux Tool Deployment Framework
  v${MINSTALLER_VERSION}
EOF
    printf '\n'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    print_banner

    # Root check (outside dry-run — even dry-run should warn if not root)
    if [[ "${EUID}" -ne 0 ]]; then
        log_warn "Not running as root. Most operations will fail unless --dry-run is used."
        if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
            die "Please run as root: sudo ${BASH_SOURCE[0]} $*"
        fi
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_safety_warn "DRY-RUN MODE: No changes will be made to the system."
    fi

    if [[ "${NONINTERACTIVE:-0}" -eq 1 ]]; then
        log_info "Noninteractive mode: all prompts answered automatically."
    fi

    log_info "Selected modules: ${SELECTED_MODULES[*]}"
    printf '\n'

    local failed_modules=()
    local mod
    for mod in "${SELECTED_MODULES[@]}"; do
        if ! run_module "${mod}"; then
            log_error "Module '${mod}' failed."
            failed_modules+=("${mod}")
        fi
        printf '\n'
    done

    # Summary
    log_step "=== Installation Summary ==="
    if [[ "${#failed_modules[@]}" -eq 0 ]]; then
        log_ok "All modules completed successfully: ${SELECTED_MODULES[*]}"
    else
        log_error "The following modules encountered errors: ${failed_modules[*]}"
        log_error "Scroll up to review error messages and retry."
        exit 1
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "Dry-run complete. Re-run without --dry-run to apply changes."
    fi
}

# Guard against sourcing this script accidentally
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    log_warn "install.sh is being sourced rather than executed. This is unusual."
else
    main "$@"
fi
