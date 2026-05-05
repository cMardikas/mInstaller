#!/usr/bin/env bash
# modules/mcollector.sh — mCollector installation module for mInstaller
#
# Source of truth: mcollector-deploy-notes.md
#
# What this module does:
#   1. Preflight: check for conflicting services on required ports.
#   2. Install build-time apt packages (build-essential, libssl-dev, git, xxd).
#      xxd is required by the mCollector Makefile to embed assets
#      (index.html, mCollector.ps1) into the binary via `xxd -i`.
#   3. Clone (or update) the mCollector repository to /opt/mCollector/src.
#   4. Build the binary with make.
#   5. Keep only /opt/mCollector/src as a subfolder; place runtime files at
#      the root of /opt/mCollector.
#   6. Copy the binary and koondraport.py beside src/. index.html and
#      mCollector.ps1 are NOT copied to the runtime root because they are
#      embedded into the binary at build time (mCollector >= 1.4.0).
#   7. Ensure /opt/mCollector/public/ exists. As of mCollector >= 1.5.0,
#      static downloadable content (e.g. PingCastle.exe) is served from
#      this folder; URLs remain /<filename> but the binary maps them to
#      public/<filename>. The directory is created if missing and
#      preserved across upgrades (operator content lives here).
#   8. Migrate stale downloadable files left at the runtime root by older
#      installer versions into public/. Currently this handles
#      PingCastle.exe: if /opt/mCollector/PingCastle.exe exists and
#      /opt/mCollector/public/PingCastle.exe does NOT, the file is moved
#      into public/. If the destination already exists, the loose copy
#      is left in place with a warning so the operator can resolve it.
#   9. Remove stale loose files left by older installer versions
#      (index.html, mCollector.ps1, embedded_assets.h) from the runtime
#      root. Preserved at the runtime root: mCollector binary,
#      koondraport.py, cert.pem/key.pem (if user-provided), uploads/
#      (captured data), public/ (static downloads served at /<file>), and
#      the src/ build checkout.
#  10. Set file permissions without creating any dedicated system user.
#  11. Set CAP_NET_BIND_SERVICE on the binary (so it can run as non-root).
#  12. Finish with manual-run guidance only. No service unit is installed.
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
_MC_KOONDRAPORT="${_MC_OPT_DIR}/koondraport.py"
_MC_UPLOADS_DIR="${_MC_OPT_DIR}/uploads"
_MC_PUBLIC_DIR="${_MC_OPT_DIR}/public"
_MC_BINARY="${_MC_OPT_DIR}/mCollector"
_MC_HASHES_FILE="${_MC_UPLOADS_DIR}/hashes.txt"

# Loose downloadable files that older installer/operator versions placed
# at the runtime root. As of mCollector >= 1.5.0, the binary serves
# static downloads from public/, so these files are migrated into
# public/<basename> on upgrade where safe. URLs remain /<basename>.
# Format: "<source-path>" — destination is always
# "${_MC_PUBLIC_DIR}/$(basename source)".
_MC_PUBLIC_MIGRATE_FILES=(
    "${_MC_OPT_DIR}/PingCastle.exe"
)

# Stale loose files that previous installer versions left at the runtime
# root. Now embedded in the binary at build time via `xxd -i`, so we
# remove them on every install to keep /opt/mCollector clean.
#   - index.html       : web UI, embedded via embedded_assets.h
#   - mCollector.ps1   : Windows agent payload, embedded via embedded_assets.h
#   - embedded_assets.h: generated header, build artifact only
_MC_STALE_RUNTIME_FILES=(
    "${_MC_OPT_DIR}/index.html"
    "${_MC_OPT_DIR}/mCollector.ps1"
    "${_MC_OPT_DIR}/embedded_assets.h"
)

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
    # xxd is required by the mCollector Makefile to generate embedded_assets.h
    # from index.html and mCollector.ps1 (`xxd -i`).
    log_step "mCollector — Installing apt packages"
    apt_update
    apt_install build-essential libssl-dev git xxd

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
        log_dryrun "[build] copy '${_MC_SRC_DIR}' to a temporary workspace and run 'make clean && make' as an unprivileged user"
        log_dryrun "[build] copy built artifact 'mCollector' to '${_MC_BINARY}'"
    else
        run_make_unprivileged "mcollector" "${_MC_SRC_DIR}" "mCollector" "${_MC_BINARY}" 1
        chmod 750 "${_MC_BINARY}"
        log_ok "Build complete"
    fi

    # --- 4. Runtime layout ----------------------------------------------------
    # uploads/ holds captured data; public/ holds operator-supplied static
    # downloads that the binary serves at /<filename> (mapped to
    # public/<filename>). Both directories are created if missing and
    # preserved across upgrades — the installer never deletes their contents.
    log_step "mCollector — Creating flat runtime layout"
    system_mkdir "${_MC_UPLOADS_DIR}"  ""  ""
    system_mkdir "${_MC_PUBLIC_DIR}"   ""  ""

    # --- 5. Copy binary and runtime files -------------------------------------
    # NOTE: index.html and mCollector.ps1 are intentionally NOT copied to the
    # runtime root. As of mCollector >= 1.4.0 they are embedded into the
    # binary at build time via `xxd -i` (see embedded_assets.h). Only files
    # that the binary genuinely reads from disk at runtime, or that the
    # operator runs manually, should live in /opt/mCollector.
    #
    # Preserved at /opt/mCollector:
    #   - mCollector       (binary)
    #   - koondraport.py   (manual fleet-report generator, run by operator)
    #   - cert.pem/key.pem (if operator placed them there; not managed here)
    #   - uploads/         (captured data; never touched by installer)
    #   - src/             (build checkout; required for rebuilds)
    log_step "mCollector — Installing binary and required files"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[build] install built mCollector binary at '${_MC_BINARY}' with mode 750"
        log_dryrun "[install] cp '${_MC_SRC_DIR}/koondraport.py' '${_MC_KOONDRAPORT}'"
        for _src in "${_MC_PUBLIC_MIGRATE_FILES[@]}"; do
            log_dryrun "[install] if '${_src}' exists and '${_MC_PUBLIC_DIR}/$(basename "${_src}")' does not, mv '${_src}' → '${_MC_PUBLIC_DIR}/'"
        done
        for _stale in "${_MC_STALE_RUNTIME_FILES[@]}"; do
            log_dryrun "[install] rm -f '${_stale}' (stale; embedded in binary)"
        done
    else
        [[ -f "${_MC_BINARY}" ]] \
            || die "Built mCollector binary not found at '${_MC_BINARY}'"
        chmod 750 "${_MC_BINARY}"

        [[ -f "${_MC_SRC_DIR}/koondraport.py" ]] \
            && cp "${_MC_SRC_DIR}/koondraport.py" "${_MC_KOONDRAPORT}"

        # Migrate loose downloadable files into public/. mCollector >= 1.5.0
        # serves these from public/<file> while keeping URLs at /<file>, so
        # legacy copies at the runtime root are no longer reachable.
        # Conservative migration: only move when the destination does not
        # already exist. If both exist, the operator likely placed the new
        # one deliberately — leave both in place and warn.
        local _src _dest
        for _src in "${_MC_PUBLIC_MIGRATE_FILES[@]}"; do
            [[ -f "${_src}" ]] || continue
            _dest="${_MC_PUBLIC_DIR}/$(basename "${_src}")"
            if [[ -e "${_dest}" ]]; then
                log_warn "Both '${_src}' and '${_dest}' exist; leaving the loose copy in place. Remove '${_src}' manually once you have confirmed '${_dest}' is the version you want served."
                continue
            fi
            log_info "Migrating '${_src}' → '${_dest}'"
            if mv "${_src}" "${_dest}"; then
                log_ok "Moved '${_src}' to public/"
            else
                log_warn "Failed to migrate '${_src}' to '${_dest}'; leaving source in place."
            fi
        done

        # Remove stale loose files from previous installer versions. These
        # are now embedded in the binary; leaving them on disk is misleading
        # (operators may edit them expecting changes to take effect).
        for _stale in "${_MC_STALE_RUNTIME_FILES[@]}"; do
            if [[ -e "${_stale}" ]]; then
                log_info "Removing stale runtime file: ${_stale}"
                rm -f "${_stale}" \
                    || log_warn "Failed to remove stale file: ${_stale}"
            fi
        done

        log_ok "Binary and runtime files installed"
    fi

    # --- 6. Permissions -------------------------------------------------------
    log_step "mCollector — Setting permissions"
    system_chmod "750" "${_MC_UPLOADS_DIR}"
    system_chmod "755" "${_MC_PUBLIC_DIR}"

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
        log_warn "mCollector is installed with restricted execute permissions (mode 750). Adjust them manually only if you understand the security impact."
    fi

    # --- 8. Manual run guidance -----------------------------------------------
    log_ok "mCollector installation complete."
    log_warn "Resolve any conflicting services (see preflight output) then run manually if needed:"
    log_warn "  cd ${_MC_OPT_DIR}"
    log_warn "  sudo ${_MC_BINARY}"
    log_warn "To clear captured uploads manually:"
    log_warn "  sudo ${_MC_BINARY} --clear"
}
