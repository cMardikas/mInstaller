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
#   5. Keep only /opt/mScreenshot/src as a subfolder; place runtime files at
#      the root of /opt/mScreenshot.
#   6. Copy the built binary and required helper files beside src/.
#   7. Copy the required `scripts/` directory and `nmap-bootstrap.xsl` out of
#      src into the install root.
#   8. Do not create extra runtime directories or symlinks.
#   9. Keep the install manual-run only. No service or timer is installed.
#
# Requires: lib/{log,apt,git,system,preflight}.sh sourced.
# Globals read: DRY_RUN, NONINTERACTIVE, MINSTALLER_ROOT

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_MS_REPO_URL="https://github.com/cMardikas/mScreenshot.git"
_MS_OPT_DIR="/opt/mScreenshot"
_MS_SRC_DIR="${_MS_OPT_DIR}/src"
_MS_BINARY="${_MS_OPT_DIR}/mScreenshot"
_MS_RUNTIME_SCRIPTS_DIR="${_MS_OPT_DIR}/scripts"
_MS_XSLT="${_MS_OPT_DIR}/nmap-bootstrap.xsl"

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
# _ms_check_chromium_path — warn if expected Chromium binary path is missing
# ---------------------------------------------------------------------------
_ms_check_chromium_path() {
    if [[ -x /usr/bin/chromium || -x /usr/bin/chromium-browser || -x /usr/bin/google-chrome ]]; then
        log_debug "A Chromium-compatible browser binary is present"
        return 0
    fi

    log_warn \
        "Chromium binary not found at /usr/bin/chromium, /usr/bin/chromium-browser, or /usr/bin/google-chrome. " \
        "Screenshots will fail until you install chromium or adjust the path manually in /opt/mScreenshot/src/scripts/screenshot.py"
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

    # --- 4. Install flat root layout, binary, and permissions -----------------
    log_step "mScreenshot — Creating flat runtime layout"

    if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
        mkdir -p "${_MS_OPT_DIR}"
        [[ -f "${_MS_SRC_DIR}/mScreenshot" ]] && cp "${_MS_SRC_DIR}/mScreenshot" "${_MS_BINARY}"
        chmod 0755 "${_MS_OPT_DIR}"
        [[ -f "${_MS_BINARY}" ]] && chmod 0755 "${_MS_BINARY}"
        if [[ -d "${_MS_SRC_DIR}/scripts" ]]; then
            rm -rf "${_MS_RUNTIME_SCRIPTS_DIR}"
            cp -R "${_MS_SRC_DIR}/scripts" "${_MS_RUNTIME_SCRIPTS_DIR}"
            find "${_MS_RUNTIME_SCRIPTS_DIR}" -type d -exec chmod 0755 {} +
            find "${_MS_RUNTIME_SCRIPTS_DIR}" -type f -exec chmod 0644 {} +
        fi
        [[ -f "${_MS_SRC_DIR}/nmap-bootstrap.xsl" ]] && {
            cp "${_MS_SRC_DIR}/nmap-bootstrap.xsl" "${_MS_XSLT}"
            chmod 0644 "${_MS_XSLT}"
        }
    else
        log_dryrun "[system] mkdir -p '${_MS_OPT_DIR}'"
        log_dryrun "[install] cp '${_MS_SRC_DIR}/mScreenshot' '${_MS_BINARY}'"
        log_dryrun "[install] cp -R '${_MS_SRC_DIR}/scripts' '${_MS_RUNTIME_SCRIPTS_DIR}'"
        log_dryrun "[install] cp '${_MS_SRC_DIR}/nmap-bootstrap.xsl' '${_MS_XSLT}'"
        log_dryrun "[system] chmod 0755 '${_MS_OPT_DIR}' '${_MS_BINARY}'"
        log_dryrun "[system] find '${_MS_RUNTIME_SCRIPTS_DIR}' -type d -exec chmod 0755 {} +"
        log_dryrun "[system] find '${_MS_RUNTIME_SCRIPTS_DIR}' -type f -exec chmod 0644 {} +"
        log_dryrun "[system] chmod 0644 '${_MS_XSLT}'"
    fi

    # --- 5. Chromium path check -----------------------------------------------
    log_step "mScreenshot — Checking Chromium binary path"
    _ms_check_chromium_path

    # --- 6. Manual run guidance -----------------------------------------------
    log_ok "mScreenshot installation complete."
    log_warn "The full scripts/ directory tree and nmap-bootstrap.xsl were copied out of src."
    log_warn "To run a scan manually from your chosen working directory:"
    log_warn "  sudo /opt/mScreenshot/mScreenshot -d '<description>' <target>"
    log_warn "If chromium/screenshot.py still fails, check /dev/shm size and AppArmor:"
    log_warn "  mount | grep shm"
    log_warn "  aa-status | grep chromium"
}
