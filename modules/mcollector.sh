#!/usr/bin/env bash
# modules/mcollector.sh — mCollector installation module for mInstaller
#
# Source of truth: mcollector-deploy-notes.md
#
# What this module does:
#   1. Preflight: check for conflicting services on required ports.
#   2. Install build-time apt packages (build-essential, libssl-dev, git).
#   3. Clone (or update) the mCollector repository to /opt/mCollector/src.
#   4. Build the binary with make.
#   5. Keep only /opt/mCollector/src as a subfolder; place runtime files at
#      the root of /opt/mCollector.
#   6. Copy the binary and required web/runtime files beside src/.
#   7. Set file permissions without creating any dedicated system user.
#   8. Set CAP_NET_BIND_SERVICE on the binary (so it can run as non-root).
#   9. Finish with manual-run guidance only. No service unit is installed.
#
# Conflicting services (printed and optionally disabled):
#   systemd-resolved (port 5355/UDP LLMNR)
#   smbd / nmbd      (port 445/TCP)
#   avahi-daemon     (port 5353/UDP mDNS)
#   apache2 / nginx  (ports 80/443/TCP)
#
# Requires: lib/{log,apt,git,system,preflight}.sh sourced.
# Globals read: DRY_RUN, NONINTERACTIVE, MINSTALLER_ROOT

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_MC_REPO_URL="https://github.com/cMardikas/mCollector.git"
_MC_OPT_DIR="/opt/mCollector"
_MC_SRC_DIR="${_MC_OPT_DIR}/src"
_MC_TLS_CERT="${_MC_OPT_DIR}/cert.pem"
_MC_TLS_KEY="${_MC_OPT_DIR}/key.pem"
_MC_INDEX_HTML="${_MC_OPT_DIR}/index.html"
_MC_PS1="${_MC_OPT_DIR}/mCollector.ps1"
_MC_UPLOADS_DIR="${_MC_OPT_DIR}/uploads"
_MC_BINARY="${_MC_OPT_DIR}/mCollector"
_MC_HASHES_FILE="${_MC_UPLOADS_DIR}/hashes.txt"

# ---------------------------------------------------------------------------
# _mc_conflicting_services — associative description of conflicts
# ---------------------------------------------------------------------------
#   Array of "service:reason" pairs
_MC_CONFLICT_SERVICES=(
    "systemd-resolved:binds UDP 5355 (LLMNR) — mCollector cannot bind LLMNR responder"
    "smbd:binds TCP 445 (SMB) — mCollector cannot run its rogue SMB2 server"
    "nmbd:companion to smbd (NetBIOS name service)"
    "avahi-daemon:binds UDP 5353 (mDNS) — mCollector cannot run its mDNS responder"
    "apache2:binds TCP 80/443 — mCollector cannot run its HTTP/HTTPS file server"
    "nginx:binds TCP 80/443 — mCollector cannot run its HTTP/HTTPS file server"
)

# ---------------------------------------------------------------------------
# module_mcollector_preflight
#   Runs all pre-installation safety checks. Called before any changes.
# ---------------------------------------------------------------------------
module_mcollector_preflight() {
    log_step "mCollector — Preflight Checks"

    preflight_require_root
    preflight_check_os

    # Warn about privileged ports
    preflight_warn_privileged_ports "80/tcp, 443/tcp, 445/tcp, 5353/udp, 5355/udp"

    # Check each conflicting service
    local entry svc reason conflict_found=0
    for entry in "${_MC_CONFLICT_SERVICES[@]}"; do
        svc="${entry%%:*}"
        reason="${entry#*:}"
        preflight_check_service_conflict "${svc}" "${reason}" || conflict_found=1
    done

    # Check ports directly
    local port_clear=1
    preflight_check_port_tcp 80   || port_clear=0
    preflight_check_port_tcp 443  || port_clear=0
    preflight_check_port_tcp 445  || port_clear=0
    preflight_check_port_udp 5353 || port_clear=0
    preflight_check_port_udp 5355 || port_clear=0

    if [[ "${conflict_found}" -eq 1 ]] || [[ "${port_clear}" -eq 0 ]]; then
        log_safety_warn \
            "One or more conflicting services or busy ports were detected (see warnings above). " \
            "mCollector will be installed, but it will NOT start correctly until conflicts are resolved. " \
            "The installer will NOT automatically disable conflicting services. " \
            "Resolve conflicts manually before running mCollector manually."
    fi

    preflight_check_disk_space "/opt" 100
    log_ok "Preflight complete."
}

# ---------------------------------------------------------------------------
# module_mcollector_install — main install function
# ---------------------------------------------------------------------------
module_mcollector_install() {
    log_step "mCollector — Installation"

    # --- 1. apt packages -------------------------------------------------------
    log_step "mCollector — Installing apt packages"
    apt_update
    apt_install build-essential libssl-dev git

    # --- 2. Clone / update source ---------------------------------------------
    log_step "mCollector — Cloning/updating repository"
    if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
        mkdir -p "${_MC_OPT_DIR}"
    else
        log_dryrun "[system] mkdir -p '${_MC_OPT_DIR}'"
    fi
    git_clone_or_update "${_MC_REPO_URL}" "${_MC_SRC_DIR}"

    # --- 3. Build -------------------------------------------------------------
    log_step "mCollector — Building"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[build] cd '${_MC_SRC_DIR}' && make clean && make"
    else
        log_info "Running make in ${_MC_SRC_DIR}"
        ( cd "${_MC_SRC_DIR}" && make clean && make ) \
            || die "mCollector build failed"
        log_ok "Build complete"
    fi

    # --- 4. Runtime layout ----------------------------------------------------
    log_step "mCollector — Creating flat runtime layout"
    system_mkdir "${_MC_UPLOADS_DIR}"  ""  ""

    # --- 5. Copy binary and assets --------------------------------------------
    log_step "mCollector — Installing binary and required files"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[install] cp '${_MC_SRC_DIR}/mCollector' '${_MC_BINARY}'"
        log_dryrun "[install] cp '${_MC_SRC_DIR}/index.html' '${_MC_INDEX_HTML}'"
        log_dryrun "[install] cp '${_MC_SRC_DIR}/mCollector.ps1' '${_MC_PS1}'"
    else
        cp "${_MC_SRC_DIR}/mCollector" "${_MC_BINARY}" \
            || die "Failed to copy mCollector binary"
        chmod 755 "${_MC_BINARY}"

        [[ -f "${_MC_SRC_DIR}/index.html" ]] \
            && cp "${_MC_SRC_DIR}/index.html" "${_MC_INDEX_HTML}"
        [[ -f "${_MC_SRC_DIR}/mCollector.ps1" ]] \
            && cp "${_MC_SRC_DIR}/mCollector.ps1" "${_MC_PS1}"
        log_ok "Binary and runtime files installed"
    fi

    # --- 6. Permissions -------------------------------------------------------
    log_step "mCollector — Setting permissions"
    system_chmod "750" "${_MC_UPLOADS_DIR}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[install] touch '${_MC_HASHES_FILE}' (if absent)"
        log_dryrun "[system] chmod '640' '${_MC_HASHES_FILE}'"
    else
        if [[ ! -f "${_MC_HASHES_FILE}" ]]; then
            touch "${_MC_HASHES_FILE}"
        fi
        chmod 640 "${_MC_HASHES_FILE}"
    fi

    # Optional TLS materials, if later added manually
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] if present, chmod '640' '${_MC_TLS_CERT}' '${_MC_TLS_KEY}'"
    else
        for _tls_file in "${_MC_TLS_CERT}" "${_MC_TLS_KEY}"; do
            if [[ -f "${_tls_file}" ]]; then
                chmod 640 "${_tls_file}"
            fi
        done
    fi

    # --- 7. CAP_NET_BIND_SERVICE on binary ------------------------------------
    log_step "mCollector — Setting capabilities on binary"
    if command -v setcap &>/dev/null; then
        system_setcap "cap_net_bind_service=+ep" "${_MC_BINARY}"
    else
        log_warn "setcap not found. Binary will require root to bind privileged ports."
    fi

    # --- 8. Manual run guidance -----------------------------------------------
    log_ok "mCollector installation complete."
    log_warn "No service was installed, enabled, or started."
    log_warn "Resolve any conflicting services (see preflight output) then run manually if needed:"
    log_warn "  cd ${_MC_OPT_DIR}"
    log_warn "  sudo ${_MC_BINARY}"
    log_warn "To clear captured uploads manually:"
    log_warn "  sudo ${_MC_BINARY} --clear"
}
