#!/usr/bin/env bash
# modules/mscreenshot.sh — mScreenshot installation module for mInstaller
#
# Source of truth: mscreenshot-deploy-notes.md
#
# What this module does:
#   1. Preflight: verify root, OS, disk space, dependency availability.
#   2. Install apt packages: build-essential, nmap, xsltproc, chromium,
#      chromium-driver, python3, python3-selenium.
#   3. Clone (or update) the mScreenshot repository to /opt/mScreenshot/src.
#   4. Build the binary with make.
#   5. Set ownership and permissions on install directory.
#   6. Create /opt/mScreenshot/reports with setgid permissions.
#   7. Create system group 'mscreenshot'.
#   8. Add the active (invoking) user to the group (optional, with prompt).
#   9. Install sudoers fragment for the mscreenshot group (optional).
#  10. Create /usr/local/bin/mscreenshot symlink.
#  11. Patch chromium binary path symlink if needed.
#  12. Write a helper scan-wrapper script (/opt/mScreenshot/run-scan.sh).
#  13. Finish with manual-run guidance only. No service or timer is installed.
#
# Requires: lib/{log,apt,git,system,systemd,preflight}.sh sourced.
# Globals read: DRY_RUN, NONINTERACTIVE, MINSTALLER_ROOT

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_MS_REPO_URL="https://github.com/cMardikas/mScreenshot.git"
_MS_OPT_DIR="/opt/mScreenshot"
_MS_SRC_DIR="${_MS_OPT_DIR}/src"
_MS_BINARY="${_MS_OPT_DIR}/mScreenshot"
_MS_REPORTS_DIR="${_MS_OPT_DIR}/reports"
_MS_GROUP="mscreenshot"
_MS_SYMLINK="/usr/local/bin/mscreenshot"
_MS_WRAPPER="${_MS_OPT_DIR}/run-scan.sh"
_MS_SUDOERS_FRAG="mscreenshot"

_MS_APT_PACKAGES=(
    build-essential
    nmap
    xsltproc
    chromium
    chromium-driver
    python3
    python3-selenium
)

# ---------------------------------------------------------------------------
# module_mscreenshot_preflight
# ---------------------------------------------------------------------------
module_mscreenshot_preflight() {
    log_step "mScreenshot — Preflight Checks"

    preflight_require_root
    preflight_check_os
    preflight_check_disk_space "/opt" 500  # Chromium + build deps are large

    # Warn about root requirement (nmap raw sockets)
    log_safety_warn \
        "mScreenshot requires root to run (nmap uses raw sockets for SYN scanning). " \
        "The binary performs getuid()==0 checks at runtime and will exit if not root."

    log_ok "Preflight complete."
}

# ---------------------------------------------------------------------------
# _ms_generate_wrapper_script — prints a multi-target scan wrapper
# ---------------------------------------------------------------------------
_ms_generate_wrapper_script() {
    cat <<'EOF'
#!/usr/bin/env bash
# /opt/mScreenshot/run-scan.sh
# Helper wrapper for running mScreenshot against multiple targets.
# Edit TARGETS and DESC below, then run as root.
#
# Usage: sudo /opt/mScreenshot/run-scan.sh
set -euo pipefail

TARGETS="${MSCREENSHOT_TARGETS:-127.0.0.1}"
DESC="${MSCREENSHOT_DESC:-$(date +%Y%m%d)}"
REPORT_DIR="/opt/mScreenshot/reports"
BINARY="/opt/mScreenshot/mScreenshot"

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Must be run as root." >&2
    exit 1
fi

cd "${REPORT_DIR}"
for target in ${TARGETS}; do
    echo "[run-scan.sh] Scanning: ${target} (desc: ${DESC})"
    "${BINARY}" -d "${DESC}" "${target}" || {
        echo "[run-scan.sh] WARNING: scan of ${target} returned non-zero" >&2
    }
done

echo "[run-scan.sh] All scans complete. Reports are in: ${REPORT_DIR}"
EOF
}

# ---------------------------------------------------------------------------
# _ms_fix_chromium_symlink — patch /usr/bin/chromium if missing
# ---------------------------------------------------------------------------
_ms_fix_chromium_symlink() {
    if [[ -x /usr/bin/chromium ]]; then
        log_debug "Chromium at /usr/bin/chromium — OK"
        return 0
    fi

    if [[ -x /usr/bin/chromium-browser ]]; then
        log_warn "/usr/bin/chromium not found; creating symlink from /usr/bin/chromium-browser"
        system_symlink /usr/bin/chromium-browser /usr/bin/chromium
    elif [[ -x /usr/bin/google-chrome ]]; then
        log_warn "/usr/bin/chromium not found; creating symlink from /usr/bin/google-chrome"
        system_symlink /usr/bin/google-chrome /usr/bin/chromium
    else
        log_warn \
            "Chromium binary not found at /usr/bin/chromium, /usr/bin/chromium-browser, or /usr/bin/google-chrome. " \
            "Screenshots will fail. Install chromium via apt or set the path manually in /opt/mScreenshot/src/scripts/screenshot.py"
    fi
}

# ---------------------------------------------------------------------------
# _ms_maybe_add_user_to_group — prompt/noninteractive add of invoking user
# ---------------------------------------------------------------------------
_ms_maybe_add_user_to_group() {
    # Determine the real (non-root) user who invoked sudo, if any.
    local real_user="${SUDO_USER:-}"
    if [[ -z "${real_user}" || "${real_user}" == "root" ]]; then
        log_debug "No SUDO_USER set — skipping group membership for current user."
        return 0
    fi

    if [[ "${NONINTERACTIVE:-0}" -eq 1 ]]; then
        log_info "Noninteractive mode: adding '${real_user}' to group '${_MS_GROUP}'"
        system_add_user_to_group "${real_user}" "${_MS_GROUP}"
        return 0
    fi

    local answer="y"
    read -r -p "Add user '${real_user}' to group '${_MS_GROUP}'? [Y/n] " answer || true
    case "${answer,,}" in
        ""| y | yes)
            system_add_user_to_group "${real_user}" "${_MS_GROUP}"
            log_info "Note: group membership takes effect on next login."
            ;;
        *)
            log_info "Skipping: user '${real_user}' not added to '${_MS_GROUP}' group."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# _ms_maybe_install_sudoers — optional sudoers fragment
# ---------------------------------------------------------------------------
_ms_maybe_install_sudoers() {
    local dest="/etc/sudoers.d/${_MS_SUDOERS_FRAG}"
    local content="%${_MS_GROUP} ALL=(root) NOPASSWD: ${_MS_BINARY}"

    if [[ -f "${dest}" ]]; then
        log_debug "Sudoers fragment already exists: ${dest}"
        return 0
    fi

    if [[ "${NONINTERACTIVE:-0}" -eq 1 ]]; then
        log_info "Noninteractive mode: installing sudoers fragment for group '${_MS_GROUP}'"
        system_install_sudoers "${_MS_SUDOERS_FRAG}" "${content}"
        return 0
    fi

    local answer="y"
    read -r -p "Install sudoers rule (allow group '${_MS_GROUP}' to run mScreenshot as root without password)? [Y/n] " answer || true
    case "${answer,,}" in
        "" | y | yes)
            system_install_sudoers "${_MS_SUDOERS_FRAG}" "${content}"
            ;;
        *)
            log_info "Sudoers fragment not installed. Group members must use 'sudo mscreenshot' with password."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# module_mscreenshot_install — main install function
# ---------------------------------------------------------------------------
module_mscreenshot_install() {
    log_step "mScreenshot — Installation"

    # --- 1. apt packages -------------------------------------------------------
    log_step "mScreenshot — Installing apt packages"
    apt_update
    apt_install "${_MS_APT_PACKAGES[@]}"

    # --- 2. Clone / update source ---------------------------------------------
    log_step "mScreenshot — Cloning/updating repository"
    if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
        mkdir -p "${_MS_OPT_DIR}"
    else
        log_dryrun "[system] mkdir -p '${_MS_OPT_DIR}'"
    fi
    git_clone_or_update "${_MS_REPO_URL}" "${_MS_SRC_DIR}"

    # --- 3. Build -------------------------------------------------------------
    log_step "mScreenshot — Building"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[build] cd '${_MS_SRC_DIR}' && make"
    else
        log_info "Running make in ${_MS_SRC_DIR}"
        ( cd "${_MS_SRC_DIR}" && make ) \
            || die "mScreenshot build failed"
        log_ok "Build complete"
    fi

    # --- 4. Install root layout, binary, and permissions ----------------------
    log_step "mScreenshot — Creating group and setting permissions"
    system_create_group "${_MS_GROUP}"

    if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
        mkdir -p "${_MS_OPT_DIR}"
        [[ -f "${_MS_SRC_DIR}/mScreenshot" ]] && cp "${_MS_SRC_DIR}/mScreenshot" "${_MS_BINARY}"
        chown -R "root:${_MS_GROUP}" "${_MS_OPT_DIR}"
        chmod 0750 "${_MS_OPT_DIR}"
        [[ -f "${_MS_BINARY}" ]] && chmod 0750 "${_MS_BINARY}"
        [[ -d "${_MS_SRC_DIR}/scripts" ]] && {
            chmod 0755 "${_MS_SRC_DIR}/scripts"
            chmod 0644 "${_MS_SRC_DIR}/scripts/"* 2>/dev/null || true
        }
        [[ -f "${_MS_SRC_DIR}/nmap-bootstrap.xsl" ]] \
            && chmod 0644 "${_MS_SRC_DIR}/nmap-bootstrap.xsl"
    else
        log_dryrun "[system] mkdir -p '${_MS_OPT_DIR}'"
        log_dryrun "[install] cp '${_MS_SRC_DIR}/mScreenshot' '${_MS_BINARY}'"
        log_dryrun "[system] chown -R root:${_MS_GROUP} '${_MS_OPT_DIR}'"
        log_dryrun "[system] chmod 0750 '${_MS_OPT_DIR}' '${_MS_BINARY}'"
    fi

    # --- 5. Reports directory (setgid) -----------------------------------------
    log_step "mScreenshot — Creating reports directory"
    system_mkdir "${_MS_REPORTS_DIR}" "root:${_MS_GROUP}" ""
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] chmod 2770 '${_MS_REPORTS_DIR}'"
    else
        chmod 2770 "${_MS_REPORTS_DIR}"
    fi

    # --- 6. Add invoking user to group ----------------------------------------
    _ms_maybe_add_user_to_group

    # --- 7. Sudoers fragment (optional) ----------------------------------------
    _ms_maybe_install_sudoers

    # --- 8. PATH symlink -------------------------------------------------------
    log_step "mScreenshot — Creating PATH symlink"
    system_symlink "${_MS_BINARY}" "${_MS_SYMLINK}"

    # --- 9. Chromium path fix (if needed) -------------------------------------
    log_step "mScreenshot — Checking Chromium binary path"
    _ms_fix_chromium_symlink

    # --- 10. Helper wrapper script --------------------------------------------
    log_step "mScreenshot — Installing scan wrapper script"
    local wrapper_content
    wrapper_content="$(_ms_generate_wrapper_script)"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[install] write wrapper script: '${_MS_WRAPPER}'"
    else
        printf '%s\n' "${wrapper_content}" > "${_MS_WRAPPER}"
        chmod 0750 "${_MS_WRAPPER}"
        chown "root:${_MS_GROUP}" "${_MS_WRAPPER}"
        log_ok "Wrapper script installed: ${_MS_WRAPPER}"
    fi

    # --- 11. Manual run guidance ----------------------------------------------
    log_ok "mScreenshot installation complete."
    log_warn "No service or timer was installed, enabled, or started."
    log_warn "To run a scan manually:"
    log_warn "  cd /opt/mScreenshot/reports"
    log_warn "  sudo mscreenshot -d '<description>' <target>"
    log_warn "To use the multi-target wrapper:"
    log_warn "  sudo ${_MS_WRAPPER}"
    log_warn "If chromium/screenshot.py still fails, check /dev/shm size and AppArmor:"
    log_warn "  mount | grep shm"
    log_warn "  aa-status | grep chromium"
}
