#!/usr/bin/env bash
# lib/log.sh — Logging and output helpers for mInstaller
# All output goes to stderr so stdout can remain clean for scripting.
# Colour codes are disabled automatically when not writing to a terminal.

# ---------------------------------------------------------------------------
# Colour setup
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
    _CLR_RESET='\033[0m'
    _CLR_BOLD='\033[1m'
    _CLR_RED='\033[0;31m'
    _CLR_YELLOW='\033[0;33m'
    _CLR_GREEN='\033[0;32m'
    _CLR_CYAN='\033[0;36m'
    _CLR_MAGENTA='\033[0;35m'
else
    _CLR_RESET=''
    _CLR_BOLD=''
    _CLR_RED=''
    _CLR_YELLOW=''
    _CLR_GREEN=''
    _CLR_CYAN=''
    _CLR_MAGENTA=''
fi

# ---------------------------------------------------------------------------
# Log-level constants (higher = more verbose)
# ---------------------------------------------------------------------------
LOG_LEVEL_ERROR=0
LOG_LEVEL_WARN=1
LOG_LEVEL_INFO=2
LOG_LEVEL_DEBUG=3

# Default — can be overridden by the caller before sourcing or after.
: "${MINSTALLER_LOG_LEVEL:=${LOG_LEVEL_INFO}}"

# ---------------------------------------------------------------------------
# Internal timestamp helper
# ---------------------------------------------------------------------------
_log_ts() { date '+%H:%M:%S'; }

# ---------------------------------------------------------------------------
# Public logging functions
# ---------------------------------------------------------------------------

# log_info <message>  — normal progress output (green prefix)
log_info() {
    [[ "${MINSTALLER_LOG_LEVEL}" -ge "${LOG_LEVEL_INFO}" ]] || return 0
    printf '%b[%s INFO ]%b  %s\n' \
        "${_CLR_GREEN}" "$(_log_ts)" "${_CLR_RESET}" "$*" >&2
}

# log_ok <message>  — success confirmation (bold green)
log_ok() {
    [[ "${MINSTALLER_LOG_LEVEL}" -ge "${LOG_LEVEL_INFO}" ]] || return 0
    printf '%b[%s  OK  ]%b  %s\n' \
        "${_CLR_GREEN}${_CLR_BOLD}" "$(_log_ts)" "${_CLR_RESET}" "$*" >&2
}

# log_warn <message>  — non-fatal warning (yellow)
log_warn() {
    [[ "${MINSTALLER_LOG_LEVEL}" -ge "${LOG_LEVEL_WARN}" ]] || return 0
    printf '%b[%s WARN ]%b  %s\n' \
        "${_CLR_YELLOW}" "$(_log_ts)" "${_CLR_RESET}" "$*" >&2
}

# log_error <message>  — fatal or actionable error (red)
log_error() {
    [[ "${MINSTALLER_LOG_LEVEL}" -ge "${LOG_LEVEL_ERROR}" ]] || return 0
    printf '%b[%s ERROR]%b  %s\n' \
        "${_CLR_RED}" "$(_log_ts)" "${_CLR_RESET}" "$*" >&2
}

# log_debug <message>  — verbose / developer output (cyan)
log_debug() {
    [[ "${MINSTALLER_LOG_LEVEL}" -ge "${LOG_LEVEL_DEBUG}" ]] || return 0
    printf '%b[%s DEBUG]%b  %s\n' \
        "${_CLR_CYAN}" "$(_log_ts)" "${_CLR_RESET}" "$*" >&2
}

# log_step <message>  — section/phase header (bold magenta)
log_step() {
    printf '\n%b==> %s%b\n' \
        "${_CLR_MAGENTA}${_CLR_BOLD}" "$*" "${_CLR_RESET}" >&2
}

# log_dryrun <message>  — dry-run action description (cyan)
log_dryrun() {
    printf '%b[%s  DRY ]%b  %s\n' \
        "${_CLR_CYAN}" "$(_log_ts)" "${_CLR_RESET}" "$*" >&2
}

# log_safety_warn <message>  — prominent safety / privilege warning (bold yellow)
log_safety_warn() {
    printf '\n%b  !! SAFETY WARNING !!%b\n%b  %s%b\n\n' \
        "${_CLR_YELLOW}${_CLR_BOLD}" "${_CLR_RESET}" \
        "${_CLR_YELLOW}" "$*" "${_CLR_RESET}" >&2
}

# ---------------------------------------------------------------------------
# die <message> [exit_code]  — print error and exit
# ---------------------------------------------------------------------------
die() {
    local msg="${1:-fatal error}"
    local code="${2:-1}"
    log_error "${msg}"
    exit "${code}"
}
