#!/usr/bin/env bash
# =============================================================================
# mInstaller — Modular Kali Linux Installer Framework
# =============================================================================
#
# Usage:
#   sudo ./mInstaller.sh [OPTIONS] <module> [<module> ...]
#   sudo ./mInstaller.sh [OPTIONS] all
#   sudo ./mInstaller.sh          (no args → interactive numbered menu)
#
# Options:
#   -h, --help            Show this help message
#   -l, --list            List available modules
#   -n, --dry-run         Print what would be done without making changes
#   -y, --noninteractive  Assume yes to all interactive prompts; selects 'all'
#                         when no module argument is given
#   -v, --verbose         Enable debug logging
#   -V, --version         Print mInstaller version
#
# Examples:
#   sudo ./mInstaller.sh                          # interactive menu
#   sudo ./mInstaller.sh all
#   sudo ./mInstaller.sh mcollector
#   sudo ./mInstaller.sh mscreenshot
#   sudo ./mInstaller.sh --dry-run all
#   sudo ./mInstaller.sh --noninteractive mcollector mscreenshot
#   sudo ./mInstaller.sh --noninteractive         # defaults to 'all'
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
MINSTALLER_VERSION="1.3.0"

# ---------------------------------------------------------------------------
# Default global flags (exported so lib functions can read them)
# ---------------------------------------------------------------------------
export DRY_RUN=0
export NONINTERACTIVE=0
export MINSTALLER_LOG_LEVEL=2   # INFO
export MINSTALLER_BANNER_PRINTED=0

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
  sudo $(basename "${BASH_SOURCE[0]}")           (no args → interactive numbered menu)

Options:
  -h, --help            Show this help message
  -l, --list            List available modules with descriptions
  -n, --dry-run         Simulate install; print what would be done (no changes)
  -y, --noninteractive  Assume 'yes' to all prompts; selects 'all' when no
                        module is specified (suitable for automation/CI)
  -U, --self-update     Update mInstaller itself from origin/main and exit
                        (without running any module)
      --no-self-update  Skip the automatic self-update check for this run
  -v, --verbose         Enable debug-level logging
  -V, --version         Print version and exit

Behavior:
  - When run from a git checkout, mInstaller automatically fast-forwards to
    origin's default branch and re-executes itself with the original
    arguments before installing. Use --no-self-update to opt out, or run
    --self-update on its own to update without installing modules.

Modules:
$(registry_list_modules)

Examples:
  # Launch interactive menu (no arguments)
  sudo ./mInstaller.sh

  # Install everything
  sudo ./mInstaller.sh all

  # Install only mCollector
  sudo ./mInstaller.sh mcollector

  # Dry-run both modules
  sudo ./mInstaller.sh --dry-run all

  # Automated (no prompts) install of mScreenshot
  sudo ./mInstaller.sh --noninteractive mscreenshot

  # Automated install — no module given, defaults to 'all'
  sudo ./mInstaller.sh --noninteractive

  # Update mInstaller itself without running any modules
  sudo ./mInstaller.sh --self-update

  # Skip the automatic update check (e.g. offline / pinned environment)
  sudo ./mInstaller.sh --no-self-update all

EOF
}

# ---------------------------------------------------------------------------
# self_update_if_needed — auto-updates mInstaller from the remote default
# branch when running inside a git checkout, then re-execs the script with the
# original arguments so the freshly pulled code takes over.
#
# Safety properties:
#   - Skips when MINSTALLER_SKIP_SELF_UPDATE=1 (set by --no-self-update or by
#     ourselves after a successful re-exec to prevent loops).
#   - Skips dry-run so simulations don't mutate the working tree.
#   - Refuses to update if the working tree has local modifications.
#   - Only fast-forwards: never rewrites or discards local commits.
#   - Outside a git checkout, warns and continues without altering files.
#   - With --self-update, updates and exits without running modules.
# ---------------------------------------------------------------------------
self_update_if_needed() {
    local do_update_only=0
    local skip_via_flag=0
    local dry_run=0
    local arg
    for arg in "$@"; do
        case "${arg}" in
            -U|--self-update) do_update_only=1 ;;
            --no-self-update) skip_via_flag=1 ;;
            -n|--dry-run)     dry_run=1 ;;
        esac
    done

    # Dry-run never mutates the working tree. Honour --self-update by
    # reporting what would happen, but do not modify files.
    if [[ "${dry_run}" -eq 1 ]]; then
        if [[ "${do_update_only}" -eq 1 ]]; then
            log_info "[dry-run] Would check for and apply mInstaller updates."
            exit 0
        fi
        log_debug "Dry-run: skipping self-update check."
        return 0
    fi

    if [[ "${skip_via_flag}" -eq 1 && "${do_update_only}" -eq 0 ]]; then
        log_debug "--no-self-update specified; skipping self-update check."
        return 0
    fi

    # Re-exec loop guard: if this process is the result of a self-update
    # re-exec, do not check again.
    if [[ "${MINSTALLER_SKIP_SELF_UPDATE:-0}" -eq 1 ]]; then
        log_debug "MINSTALLER_SKIP_SELF_UPDATE is set; skipping self-update check."
        if [[ "${do_update_only}" -eq 1 ]]; then
            log_ok "mInstaller is already up to date."
            exit 0
        fi
        return 0
    fi

    if ! command -v git &>/dev/null; then
        if [[ "${do_update_only}" -eq 1 ]]; then
            die "git is required for --self-update but is not installed."
        fi
        log_warn "git not found; cannot auto-update mInstaller. Continuing with the installed copy."
        return 0
    fi

    if ! git -C "${MINSTALLER_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
        if [[ "${do_update_only}" -eq 1 ]]; then
            die "mInstaller is not running from a git checkout; cannot --self-update. Re-clone from the upstream repository instead."
        fi
        log_warn "mInstaller is not running from a git checkout; auto-update is unavailable. Re-clone the repository to receive updates."
        return 0
    fi

    if ! git -C "${MINSTALLER_ROOT}" remote get-url origin &>/dev/null; then
        if [[ "${do_update_only}" -eq 1 ]]; then
            die "No git remote named 'origin' is configured; cannot --self-update."
        fi
        log_warn "No git remote named 'origin'; auto-update is unavailable."
        return 0
    fi

    local current_head
    current_head="$(git -C "${MINSTALLER_ROOT}" rev-parse HEAD 2>/dev/null || true)"

    if ! git -C "${MINSTALLER_ROOT}" fetch --quiet origin; then
        log_warn "Failed to fetch mInstaller updates from origin; continuing with current version."
        if [[ "${do_update_only}" -eq 1 ]]; then
            exit 1
        fi
        return 0
    fi

    # Resolve the remote's default branch. Fall back to 'main' if the symbolic
    # ref is missing (e.g. older clones where 'origin/HEAD' was never set).
    local remote_branch=""
    if remote_branch="$(git -C "${MINSTALLER_ROOT}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
        :
    elif git -C "${MINSTALLER_ROOT}" rev-parse --verify --quiet origin/main >/dev/null; then
        remote_branch="origin/main"
    elif git -C "${MINSTALLER_ROOT}" rev-parse --verify --quiet origin/master >/dev/null; then
        remote_branch="origin/master"
    else
        log_warn "Could not determine remote default branch; skipping self-update."
        if [[ "${do_update_only}" -eq 1 ]]; then
            exit 1
        fi
        return 0
    fi

    local upstream_head
    upstream_head="$(git -C "${MINSTALLER_ROOT}" rev-parse "${remote_branch}" 2>/dev/null || true)"

    if [[ -z "${upstream_head}" ]]; then
        log_warn "Unable to read ${remote_branch}; skipping self-update."
        if [[ "${do_update_only}" -eq 1 ]]; then
            exit 1
        fi
        return 0
    fi

    if [[ -n "${current_head}" && "${current_head}" == "${upstream_head}" ]]; then
        log_debug "mInstaller already up to date (${current_head:0:7})."
        if [[ "${do_update_only}" -eq 1 ]]; then
            log_ok "mInstaller is already up to date."
            exit 0
        fi
        return 0
    fi

    if [[ -n "$(git -C "${MINSTALLER_ROOT}" status --porcelain 2>/dev/null)" ]]; then
        log_warn "Local changes detected in mInstaller checkout; skipping auto-update to avoid losing work."
        log_warn "Commit, stash, or revert your changes (or use --no-self-update) to silence this warning."
        if [[ "${do_update_only}" -eq 1 ]]; then
            exit 1
        fi
        return 0
    fi

    log_info "Updating mInstaller: ${current_head:0:7} → ${upstream_head:0:7} (${remote_branch})"
    if ! git -C "${MINSTALLER_ROOT}" merge --ff-only --quiet "${upstream_head}"; then
        log_warn "Fast-forward merge to ${remote_branch} failed; continuing with current version."
        if [[ "${do_update_only}" -eq 1 ]]; then
            die "mInstaller self-update failed. Resolve git issues and retry."
        fi
        return 0
    fi
    log_ok "mInstaller updated to ${upstream_head:0:7}."

    if [[ "${do_update_only}" -eq 1 ]]; then
        log_ok "Self-update complete. Re-run mInstaller to use the new version."
        exit 0
    fi

    # Re-exec the freshly pulled script with the original arguments, setting a
    # guard env var so the new process does not loop back into self-update.
    local script_path="${MINSTALLER_ROOT}/$(basename "${BASH_SOURCE[0]}")"
    if [[ ! -x "${script_path}" ]]; then
        # Fall back to the resolved path of the current script.
        script_path="$(readlink -f "${BASH_SOURCE[0]}")"
    fi
    log_info "Re-executing updated mInstaller..."
    export MINSTALLER_SKIP_SELF_UPDATE=1
    exec "${script_path}" "$@"
}

# ---------------------------------------------------------------------------
# resolve_build_user — choose an unprivileged account for compiling third-party
# code. Prefers the invoking sudo user, otherwise falls back to nobody.
# ---------------------------------------------------------------------------
resolve_build_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s' "${SUDO_USER}"
        return 0
    fi

    if id nobody &>/dev/null; then
        printf '%s' "nobody"
        return 0
    fi

    die "Unable to determine an unprivileged build user. Run mInstaller via sudo from a normal user account."
}

# ---------------------------------------------------------------------------
# run_make_unprivileged <module_name> <source_dir> <artifact_relpath> <dest>
#                      <clean_first:0|1>
# Copies the source tree to a temporary build workspace, compiles as a non-root
# user, then copies just the requested artifact back to the destination.
# ---------------------------------------------------------------------------
run_make_unprivileged() {
    local module_name="${1:?run_make_unprivileged: missing module name}"
    local source_dir="${2:?run_make_unprivileged: missing source dir}"
    local artifact_relpath="${3:?run_make_unprivileged: missing artifact path}"
    local dest_path="${4:?run_make_unprivileged: missing destination path}"
    local clean_first="${5:-0}"

    local build_user build_group build_dir build_cmd
    build_user="$(resolve_build_user)"
    build_group="$(id -gn "${build_user}")"
    build_dir="$(mktemp -d "/tmp/minstaller-${module_name}-XXXXXX")"

    log_info "Building ${module_name} as unprivileged user '${build_user}' in a temporary workspace."
    cp -a "${source_dir}/." "${build_dir}/"
    chown -R "${build_user}:${build_group}" "${build_dir}"

    if [[ "${clean_first}" -eq 1 ]]; then
        build_cmd='set -euo pipefail; cd "$1"; make clean && make'
    else
        build_cmd='set -euo pipefail; cd "$1"; make'
    fi

    if command -v runuser &>/dev/null; then
        runuser -u "${build_user}" -- bash --noprofile --norc -c "${build_cmd}" bash "${build_dir}" \
            || die "${module_name} build failed"
    elif command -v sudo &>/dev/null; then
        sudo -u "${build_user}" HOME="${build_dir}" bash --noprofile --norc -c "${build_cmd}" bash "${build_dir}" \
            || die "${module_name} build failed"
    else
        rm -rf "${build_dir}"
        die "Neither runuser nor sudo is available for unprivileged builds."
    fi

    local artifact_path
    artifact_path="${build_dir}/${artifact_relpath}"

    if [[ ! -e "${artifact_path}" ]]; then
        rm -rf "${build_dir}"
        die "Built artifact for ${module_name} is missing: ${artifact_path}"
    fi

    if [[ -L "${artifact_path}" ]]; then
        rm -rf "${build_dir}"
        die "Refusing to install ${module_name}: built artifact is a symlink (${artifact_path})"
    fi

    if [[ ! -f "${artifact_path}" ]]; then
        rm -rf "${build_dir}"
        die "Refusing to install ${module_name}: built artifact is not a regular file (${artifact_path})"
    fi

    cp --no-dereference "${artifact_path}" "${dest_path}" \
        || { rm -rf "${build_dir}"; die "Failed to copy built artifact for ${module_name}"; }
    rm -rf "${build_dir}"
}

# ---------------------------------------------------------------------------
# show_menu — display a numbered module selection menu and populate
#             SELECTED_MODULES from the user's response.
#
# Menu items are built dynamically from MINSTALLER_MODULES so that adding
# a new module to the registry automatically appears in the menu.
# The last two fixed entries are always "all" and "quit".
#
# The user may enter:
#   - a single number          (e.g.  2)
#   - multiple numbers, space- or comma-separated  (e.g.  1 2  or  1,2)
# Selecting the "quit" entry exits with code 0.
# An invalid selection re-prompts.
# ---------------------------------------------------------------------------
show_menu() {
    local -a _menu_ids=()       # ordered IDs for menu lookup
    local -i _idx=1
    local _id _name_var _desc_var

    if [[ "${MINSTALLER_BANNER_PRINTED:-0}" -eq 0 ]]; then
        print_banner
        export MINSTALLER_BANNER_PRINTED=1
    fi

    printf '\n'
    printf '  Select module(s) to install:\n'
    printf '\n'

    # Dynamic module entries
    for _id in "${MINSTALLER_MODULES[@]}"; do
        _name_var="MODULE_${_id}_NAME"
        _desc_var="MODULE_${_id}_DESC"
        printf '  %2d) %-16s  %s\n' \
            "${_idx}" \
            "${!_name_var:-${_id}}" \
            "${!_desc_var:-}"
        _menu_ids+=("${_id}")
        _idx=$(( _idx + 1 ))
    done

    # Fixed entries: all, quit
    local _all_idx=${_idx}
    printf '  %2d) %-16s  %s\n' "${_all_idx}" "all" "Install all modules"
    _idx=$(( _idx + 1 ))
    local _quit_idx=${_idx}
    printf '  %2d) %-16s  %s\n' "${_quit_idx}" "quit" "Exit without installing"
    printf '\n'

    # Input loop
    while true; do
        printf '  Enter number(s) [1-%d]: ' "${_quit_idx}"
        local _input
        if ! read -r _input; then
            # EOF (e.g. stdin closed)
            printf '\n'
            exit 0
        fi

        # Normalise: replace commas with spaces, squeeze whitespace
        _input="${_input//,/ }"
        local -a _tokens
        read -ra _tokens <<< "${_input}"

        if [[ "${#_tokens[@]}" -eq 0 ]]; then
            printf '  No selection. Please enter one or more numbers.\n'
            continue
        fi

        local _ok=1
        local -a _chosen=()

        for _tok in "${_tokens[@]}"; do
            # Must be a positive integer
            if ! [[ "${_tok}" =~ ^[0-9]+$ ]]; then
                printf '  Invalid input: "%s" is not a number.\n' "${_tok}"
                _ok=0
                break
            fi

            local -i _n=${_tok}
            if [[ "${_n}" -lt 1 || "${_n}" -gt "${_quit_idx}" ]]; then
                printf '  Number out of range: %d (valid: 1-%d).\n' "${_n}" "${_quit_idx}"
                _ok=0
                break
            fi

            if [[ "${_n}" -eq "${_quit_idx}" ]]; then
                printf '  Quitting.\n'
                exit 0
            fi

            if [[ "${_n}" -eq "${_all_idx}" ]]; then
                _chosen=("${MINSTALLER_MODULES[@]}")
                break   # 'all' supersedes any other selection
            fi

            # _menu_ids is 0-indexed; menu is 1-indexed
            _chosen+=("${_menu_ids[$(( _n - 1 ))]}")

        done

        if [[ "${_ok}" -eq 0 ]]; then
            continue
        fi

        if [[ "${#_chosen[@]}" -eq 0 ]]; then
            printf '  No valid modules selected. Try again.\n'
            continue
        fi

        SELECTED_MODULES=("${_chosen[@]}")
        break
    done
}

# ---------------------------------------------------------------------------
# parse_args — populate globals from CLI
# ---------------------------------------------------------------------------
parse_args() {
    SELECTED_MODULES=()

    # First pass: collect flags so we know NONINTERACTIVE before deciding
    # whether to show the menu.  We do a full parse in the main loop below.
    local _has_module_arg=0
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -h|--help|-l|--list|-V|--version) ;;
            -n|--dry-run|-v|--verbose)        ;;
            -U|--self-update|--no-self-update) ;;
            -y|--noninteractive) NONINTERACTIVE=1; export NONINTERACTIVE ;;
            --) break ;;
            *) _has_module_arg=1 ;;
        esac
    done

    # If invoked with zero arguments and NOT --noninteractive, show the menu
    # immediately (before re-parsing flags, which is a no-op for zero args).
    if [[ "$#" -eq 0 ]]; then
        if [[ "${NONINTERACTIVE:-0}" -eq 1 ]]; then
            # Noninteractive + no modules → default to all
            SELECTED_MODULES=("${MINSTALLER_MODULES[@]}")
            return 0
        fi
        show_menu
        return 0
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
            -U|--self-update)
                # Handled in self_update_if_needed (runs before parse_args).
                ;;
            --no-self-update)
                # Handled in self_update_if_needed (runs before parse_args).
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

    # After full flag parse: if only flags were supplied and no module was
    # named, decide based on noninteractive mode.
    if [[ "${#SELECTED_MODULES[@]}" -eq 0 ]]; then
        if [[ "${NONINTERACTIVE:-0}" -eq 1 ]]; then
            # --noninteractive with no modules → default to all
            log_info "No modules specified; --noninteractive is set — defaulting to 'all'."
            SELECTED_MODULES=("${MINSTALLER_MODULES[@]}")
        else
            # Flags only, no modules, interactive — show the menu
            show_menu
        fi
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
mInstaller
version ${MINSTALLER_VERSION}
EOF
    printf '\n'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    self_update_if_needed "$@"
    parse_args "$@"

    if [[ "${MINSTALLER_BANNER_PRINTED:-0}" -eq 0 ]]; then
        print_banner
        export MINSTALLER_BANNER_PRINTED=1
    fi

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
    log_warn "mInstaller.sh is being sourced rather than executed. This is unusual."
else
    main "$@"
fi
