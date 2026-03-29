#!/usr/bin/env bash
# lib/preflight.sh — Preflight checks: port conflicts, service conflicts,
#                    and privilege requirements for mInstaller.
#
# Requires: lib/log.sh sourced first.
# Globals read: DRY_RUN (0/1)

# ---------------------------------------------------------------------------
# preflight_require_root
#   Exits with an error if the installer is not running as root (UID 0),
#   except in dry-run mode where it only warns.
# ---------------------------------------------------------------------------
preflight_require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            log_warn "Not running as root, but continuing because dry-run mode is enabled."
            return 0
        fi
        die "mInstaller must be run as root (or via sudo). Current UID: ${EUID}"
    fi
    log_debug "Running as root: OK"
}

# ---------------------------------------------------------------------------
# preflight_require_command <cmd> [<human_readable_description>]
#   Exits if <cmd> is not found on PATH.
# ---------------------------------------------------------------------------
preflight_require_command() {
    local cmd="${1:?preflight_require_command: missing command name}"
    local desc="${2:-${cmd}}"

    if ! command -v "${cmd}" &>/dev/null; then
        die "Required command not found: '${cmd}' (${desc}). Install it and retry."
    fi
    log_debug "Command present: ${cmd}"
}

# ---------------------------------------------------------------------------
# preflight_check_port_tcp <port>
#   Prints a warning (not fatal) if a TCP port is already in use.
#   Returns 1 if busy, 0 if free.
# ---------------------------------------------------------------------------
preflight_check_port_tcp() {
    local port="${1:?preflight_check_port_tcp: missing port}"

    if ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
        log_warn "TCP port ${port} is already in use."
        return 1
    fi
    log_debug "TCP port ${port}: free"
    return 0
}

# ---------------------------------------------------------------------------
# preflight_check_port_udp <port>
#   Same but for UDP.
# ---------------------------------------------------------------------------
preflight_check_port_udp() {
    local port="${1:?preflight_check_port_udp: missing port}"

    if ss -ulnH "sport = :${port}" 2>/dev/null | grep -q .; then
        log_warn "UDP port ${port} is already in use."
        return 1
    fi
    log_debug "UDP port ${port}: free"
    return 0
}

# ---------------------------------------------------------------------------
# preflight_check_service_conflict <service_name> <reason>
#   Warns if <service_name> is active. Does NOT stop the service.
#   Returns 1 if the service is running (conflicting), 0 if not.
# ---------------------------------------------------------------------------
preflight_check_service_conflict() {
    local svc="${1:?preflight_check_service_conflict: missing service name}"
    local reason="${2:-conflicts with the target application}"

    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        log_safety_warn \
            "Service '${svc}' is currently running and ${reason}. " \
            "Stop/disable it before starting the installed tool, or the tool may fail to bind required ports."
        return 1
    fi
    log_debug "Conflict check: '${svc}' is not running — OK"
    return 0
}

# ---------------------------------------------------------------------------
# preflight_warn_privileged_ports <ports_csv>
#   Prints a one-time advisory that the application will bind privileged
#   (< 1024) ports and requires root or CAP_NET_BIND_SERVICE.
# ---------------------------------------------------------------------------
preflight_warn_privileged_ports() {
    local ports_csv="${1:?preflight_warn_privileged_ports: missing ports}"
    log_safety_warn \
        "This application binds privileged ports (${ports_csv}). " \
        "It requires root or CAP_NET_BIND_SERVICE on the binary. " \
        "Do not run it as an unprivileged user without setting capabilities."
}

# ---------------------------------------------------------------------------
# preflight_check_disk_space <path> <min_mb>
#   Warns if available disk space at <path> is below <min_mb> megabytes.
# ---------------------------------------------------------------------------
preflight_check_disk_space() {
    local path="${1:?preflight_check_disk_space: missing path}"
    local min_mb="${2:?preflight_check_disk_space: missing minimum MB}"

    local avail_kb
    avail_kb="$(df -Pk "${path}" 2>/dev/null | awk 'NR==2 {print $4}')"
    local avail_mb=$(( avail_kb / 1024 ))

    if [[ "${avail_mb}" -lt "${min_mb}" ]]; then
        log_warn "Low disk space at ${path}: ${avail_mb} MB available (minimum recommended: ${min_mb} MB)"
        return 1
    fi
    log_debug "Disk space at ${path}: ${avail_mb} MB available — OK (min ${min_mb} MB)"
    return 0
}

# ---------------------------------------------------------------------------
# preflight_check_os
#   Warns if not running on a Debian/Kali-based system.
# ---------------------------------------------------------------------------
preflight_check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        local id_like
        id_like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-${ID}}")"
        case "${id_like}" in
            *debian*|*kali*) log_debug "OS check: Debian/Kali-compatible — OK" ; return 0 ;;
        esac
    fi
    log_warn "This installer is designed for Kali/Debian. Your OS may not be compatible."
    return 1
}
