#!/usr/bin/env bash
# lib/apt.sh — APT package installation helpers for mInstaller
#
# Requires: lib/log.sh sourced first.
# Globals read: DRY_RUN (0/1), NONINTERACTIVE (0/1)

# ---------------------------------------------------------------------------
# apt_update — run apt-get update (idempotent: skips if index is fresh)
# ---------------------------------------------------------------------------
apt_update() {
    # Check whether apt cache is less than 1 hour old to avoid redundant updates.
    local cache_stamp
    cache_stamp="$(find /var/cache/apt/pkgcache.bin -newer /var/lib/apt/lists/ \
                        -maxdepth 0 2>/dev/null || true)"

    if [[ -z "${cache_stamp}" ]]; then
        log_info "Updating apt package index..."
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            log_dryrun "[apt] apt-get update"
            return 0
        fi
        DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            || log_warn "apt-get update returned non-zero (continuing)"
    else
        log_debug "apt cache is fresh; skipping update"
    fi
}

# ---------------------------------------------------------------------------
# apt_install <pkg> [<pkg> ...]
#   Installs one or more packages. Skips packages that are already installed.
# ---------------------------------------------------------------------------
apt_install() {
    local pkgs=("$@")
    [[ "${#pkgs[@]}" -gt 0 ]] || { log_warn "apt_install called with no packages"; return 0; }

    local -a to_install=()
    for pkg in "${pkgs[@]}"; do
        if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null \
                | grep -q 'install ok installed'; then
            log_debug "Package already installed: ${pkg}"
        else
            log_debug "Package queued for install: ${pkg}"
            to_install+=("${pkg}")
        fi
    done

    if [[ "${#to_install[@]}" -eq 0 ]]; then
        log_info "All required packages are already installed."
        return 0
    fi

    log_info "Installing packages: ${to_install[*]}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[apt] apt-get install -y ${to_install[*]}"
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends "${to_install[@]}" \
        || die "apt-get install failed for: ${to_install[*]}"

    log_ok "Packages installed: ${to_install[*]}"
}

# ---------------------------------------------------------------------------
# apt_check_available <pkg>
#   Returns 0 if the package exists in the apt cache, 1 otherwise.
# ---------------------------------------------------------------------------
apt_check_available() {
    local pkg="${1:?apt_check_available: missing package name}"
    apt-cache show "${pkg}" &>/dev/null
}
