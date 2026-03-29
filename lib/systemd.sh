#!/usr/bin/env bash
# lib/systemd.sh — systemd unit management helpers for mInstaller
#
# Requires: lib/log.sh sourced first.
# Globals read: DRY_RUN (0/1)

# ---------------------------------------------------------------------------
# systemd_install_unit <unit_file_path>
#   Copies a unit file to /etc/systemd/system/ and runs daemon-reload.
# ---------------------------------------------------------------------------
systemd_install_unit() {
    local unit_file="${1:?systemd_install_unit: missing unit file path}"
    local unit_name
    unit_name="$(basename "${unit_file}")"
    local dest="/etc/systemd/system/${unit_name}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[systemd] install unit file: ${dest}"
        log_dryrun "[systemd] systemctl daemon-reload"
        return 0
    fi

    log_info "Installing systemd unit: ${dest}"
    install -m 0644 -o root -g root "${unit_file}" "${dest}" \
        || die "Failed to install systemd unit: ${dest}"
    log_ok "Unit installed: ${dest}"

    systemd_daemon_reload
}

# ---------------------------------------------------------------------------
# systemd_install_unit_content <unit_name> <content>
#   Writes a unit file from a string (useful for generated/templated units).
# ---------------------------------------------------------------------------
systemd_install_unit_content() {
    local unit_name="${1:?systemd_install_unit_content: missing unit name}"
    local content="${2:?systemd_install_unit_content: missing content}"
    local dest="/etc/systemd/system/${unit_name}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[systemd] write unit '${dest}' from template"
        printf '  -- unit content preview --\n%s\n  -- end --\n' "${content}" >&2
        log_dryrun "[systemd] systemctl daemon-reload"
        return 0
    fi

    log_info "Writing systemd unit: ${dest}"
    printf '%s\n' "${content}" > "${dest}" \
        || die "Failed to write systemd unit: ${dest}"
    chmod 0644 "${dest}"
    chown root:root "${dest}"
    log_ok "Unit written: ${dest}"

    systemd_daemon_reload
}

# ---------------------------------------------------------------------------
# systemd_daemon_reload
# ---------------------------------------------------------------------------
systemd_daemon_reload() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[systemd] systemctl daemon-reload"
        return 0
    fi

    log_debug "Running systemctl daemon-reload"
    systemctl daemon-reload || die "systemctl daemon-reload failed"
}

# ---------------------------------------------------------------------------
# systemd_enable <unit_name>
# ---------------------------------------------------------------------------
systemd_enable() {
    local unit="${1:?systemd_enable: missing unit name}"

    if systemctl is-enabled "${unit}" &>/dev/null; then
        log_debug "Unit already enabled: ${unit}"
        return 0
    fi

    log_info "Enabling systemd unit: ${unit}"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[systemd] systemctl enable '${unit}'"
        return 0
    fi

    systemctl enable "${unit}" || die "systemctl enable '${unit}' failed"
    log_ok "Unit enabled: ${unit}"
}

# ---------------------------------------------------------------------------
# systemd_disable <unit_name>
#   Disables and stops a unit. Prints exactly what it is doing before acting.
#   Must NOT be called during dry-run (callers must guard).
# ---------------------------------------------------------------------------
systemd_disable() {
    local unit="${1:?systemd_disable: missing unit name}"

    if ! systemctl is-enabled "${unit}" &>/dev/null \
       && ! systemctl is-active "${unit}" &>/dev/null; then
        log_debug "Unit already stopped/disabled: ${unit}"
        return 0
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[systemd] would stop and disable: ${unit}"
        return 0
    fi

    log_info "Stopping and disabling: ${unit}"
    systemctl stop    "${unit}" 2>/dev/null || true
    systemctl disable "${unit}" 2>/dev/null || true
    log_ok "Stopped and disabled: ${unit}"
}

# ---------------------------------------------------------------------------
# systemd_start <unit_name>
# ---------------------------------------------------------------------------
systemd_start() {
    local unit="${1:?systemd_start: missing unit name}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[systemd] systemctl start '${unit}'"
        return 0
    fi

    log_info "Starting service: ${unit}"
    systemctl start "${unit}" || die "systemctl start '${unit}' failed"
    log_ok "Service started: ${unit}"
}

# ---------------------------------------------------------------------------
# systemd_enable_now <unit_name>
#   Enable and immediately start a unit.
# ---------------------------------------------------------------------------
systemd_enable_now() {
    local unit="${1:?systemd_enable_now: missing unit name}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[systemd] systemctl enable --now '${unit}'"
        return 0
    fi

    log_info "Enabling and starting: ${unit}"
    systemctl enable --now "${unit}" || die "systemctl enable --now '${unit}' failed"
    log_ok "Service enabled and started: ${unit}"
}

# ---------------------------------------------------------------------------
# systemd_is_active <unit_name>
#   Returns 0 if the unit is currently active (running).
# ---------------------------------------------------------------------------
systemd_is_active() {
    local unit="${1:?systemd_is_active: missing unit name}"
    systemctl is-active --quiet "${unit}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# systemd_is_enabled <unit_name>
#   Returns 0 if the unit is enabled.
# ---------------------------------------------------------------------------
systemd_is_enabled() {
    local unit="${1:?systemd_is_enabled: missing unit name}"
    systemctl is-enabled --quiet "${unit}" 2>/dev/null
}
