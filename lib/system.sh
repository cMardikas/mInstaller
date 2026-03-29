#!/usr/bin/env bash
# lib/system.sh — OS-level helpers: users, groups, directories, symlinks,
#                 permissions, capabilities, and sudoers fragments.
#
# Requires: lib/log.sh sourced first.
# Globals read: DRY_RUN (0/1)

# ---------------------------------------------------------------------------
# system_create_user <username> [home_dir]
#   Creates a system (nologin) user if it does not already exist.
#   home_dir defaults to /nonexistent.
# ---------------------------------------------------------------------------
system_create_user() {
    local username="${1:?system_create_user: missing username}"
    local home_dir="${2:-/nonexistent}"

    if id -u "${username}" &>/dev/null; then
        log_debug "System user already exists: ${username}"
        return 0
    fi

    log_info "Creating system user: ${username} (home=${home_dir})"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] useradd -r -s /usr/sbin/nologin -d '${home_dir}' -M '${username}'"
        return 0
    fi

    useradd -r -s /usr/sbin/nologin -d "${home_dir}" -M "${username}" \
        || die "Failed to create system user: ${username}"
    log_ok "System user created: ${username}"
}

# ---------------------------------------------------------------------------
# system_create_group <groupname>
#   Creates a system group if it does not already exist.
# ---------------------------------------------------------------------------
system_create_group() {
    local groupname="${1:?system_create_group: missing groupname}"

    if getent group "${groupname}" &>/dev/null; then
        log_debug "Group already exists: ${groupname}"
        return 0
    fi

    log_info "Creating system group: ${groupname}"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] groupadd -r '${groupname}'"
        return 0
    fi

    groupadd -r "${groupname}" \
        || die "Failed to create group: ${groupname}"
    log_ok "Group created: ${groupname}"
}

# ---------------------------------------------------------------------------
# system_add_user_to_group <username> <groupname>
# ---------------------------------------------------------------------------
system_add_user_to_group() {
    local username="${1:?missing username}"
    local groupname="${2:?missing groupname}"

    if id -nG "${username}" 2>/dev/null | grep -qw "${groupname}"; then
        log_debug "User '${username}' is already in group '${groupname}'"
        return 0
    fi

    log_info "Adding user '${username}' to group '${groupname}'"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] usermod -aG '${groupname}' '${username}'"
        return 0
    fi

    usermod -aG "${groupname}" "${username}" \
        || die "Failed to add ${username} to ${groupname}"
    log_ok "User '${username}' added to group '${groupname}'"
}

# ---------------------------------------------------------------------------
# system_mkdir <dir> [owner:group] [mode]
#   Creates directory and optionally sets ownership + permissions.
#   Idempotent — does nothing if directory exists (but still applies chown/chmod).
# ---------------------------------------------------------------------------
system_mkdir() {
    local dir="${1:?system_mkdir: missing directory}"
    local owner="${2:-}"
    local mode="${3:-}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] mkdir -p '${dir}'"
        [[ -n "${owner}" ]] && log_dryrun "[system] chown '${owner}' '${dir}'"
        [[ -n "${mode}"  ]] && log_dryrun "[system] chmod '${mode}' '${dir}'"
        return 0
    fi

    if [[ ! -d "${dir}" ]]; then
        log_info "Creating directory: ${dir}"
        mkdir -p "${dir}" || die "mkdir -p failed: ${dir}"
    else
        log_debug "Directory already exists: ${dir}"
    fi

    if [[ -n "${owner}" ]]; then
        chown "${owner}" "${dir}" || die "chown ${owner} ${dir} failed"
    fi
    if [[ -n "${mode}" ]]; then
        chmod "${mode}" "${dir}" || die "chmod ${mode} ${dir} failed"
    fi
}

# ---------------------------------------------------------------------------
# system_symlink <target> <link_path>
#   Creates (or updates) a symbolic link. Idempotent.
# ---------------------------------------------------------------------------
system_symlink() {
    local target="${1:?system_symlink: missing target}"
    local link_path="${2:?system_symlink: missing link path}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] ln -sf '${target}' '${link_path}'"
        return 0
    fi

    if [[ -L "${link_path}" && "$(readlink "${link_path}")" == "${target}" ]]; then
        log_debug "Symlink already correct: ${link_path} → ${target}"
        return 0
    fi

    log_info "Creating symlink: ${link_path} → ${target}"
    ln -sf "${target}" "${link_path}" \
        || die "ln -sf '${target}' '${link_path}' failed"
    log_ok "Symlink: ${link_path} → ${target}"
}

# ---------------------------------------------------------------------------
# system_chown <owner:group> <path> [recursive?]
# ---------------------------------------------------------------------------
system_chown() {
    local owner="${1:?system_chown: missing owner}"
    local path="${2:?system_chown: missing path}"
    local recursive="${3:-0}"

    local flag=""
    [[ "${recursive}" -eq 1 ]] && flag="-R"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] chown ${flag} '${owner}' '${path}'"
        return 0
    fi

    # shellcheck disable=SC2086
    chown ${flag} "${owner}" "${path}" \
        || die "chown ${flag} ${owner} ${path} failed"
    log_debug "Ownership set: ${owner} on ${path}"
}

# ---------------------------------------------------------------------------
# system_chmod <mode> <path>
# ---------------------------------------------------------------------------
system_chmod() {
    local mode="${1:?system_chmod: missing mode}"
    local path="${2:?system_chmod: missing path}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] chmod '${mode}' '${path}'"
        return 0
    fi

    chmod "${mode}" "${path}" || die "chmod ${mode} ${path} failed"
    log_debug "Permissions set: ${mode} on ${path}"
}

# ---------------------------------------------------------------------------
# system_setcap <capabilities> <binary>
#   Sets POSIX capabilities on a binary.
# ---------------------------------------------------------------------------
system_setcap() {
    local caps="${1:?system_setcap: missing capabilities}"
    local binary="${2:?system_setcap: missing binary path}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] setcap '${caps}' '${binary}'"
        return 0
    fi

    log_info "Setting capabilities (${caps}) on ${binary}"
    setcap "${caps}" "${binary}" \
        || die "setcap '${caps}' '${binary}' failed"
    log_ok "Capabilities set on ${binary}"
}

# ---------------------------------------------------------------------------
# system_install_sudoers <fragment_name> <content>
#   Writes /etc/sudoers.d/<fragment_name> safely via visudo -c.
#   Content is passed as a string.
# ---------------------------------------------------------------------------
system_install_sudoers() {
    local name="${1:?system_install_sudoers: missing fragment name}"
    local content="${2:?system_install_sudoers: missing content}"
    local dest="/etc/sudoers.d/${name}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] install sudoers fragment: ${dest}"
        log_dryrun "  content: ${content}"
        return 0
    fi

    log_info "Installing sudoers fragment: ${dest}"
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "${content}" > "${tmp}"

    # Validate before installing
    if visudo -c -f "${tmp}" &>/dev/null; then
        install -m 0440 -o root -g root "${tmp}" "${dest}" \
            || { rm -f "${tmp}"; die "Failed to install sudoers fragment: ${dest}"; }
        rm -f "${tmp}"
        log_ok "Sudoers fragment installed: ${dest}"
    else
        rm -f "${tmp}"
        die "Sudoers fragment failed validation — not installed. Content was: ${content}"
    fi
}

# ---------------------------------------------------------------------------
# system_copy_file <src> <dest> [mode] [owner:group]
#   Copies a file if it differs or dest doesn't exist.
# ---------------------------------------------------------------------------
system_copy_file() {
    local src="${1:?system_copy_file: missing source}"
    local dest="${2:?system_copy_file: missing destination}"
    local mode="${3:-}"
    local owner="${4:-}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_dryrun "[system] cp '${src}' '${dest}'"
        [[ -n "${mode}"  ]] && log_dryrun "[system] chmod '${mode}' '${dest}'"
        [[ -n "${owner}" ]] && log_dryrun "[system] chown '${owner}' '${dest}'"
        return 0
    fi

    if [[ ! -f "${src}" ]]; then
        die "system_copy_file: source not found: ${src}"
    fi

    cp "${src}" "${dest}" || die "cp '${src}' '${dest}' failed"
    [[ -n "${mode}"  ]] && chmod "${mode}" "${dest}"
    [[ -n "${owner}" ]] && chown "${owner}" "${dest}"
    log_debug "File copied: ${src} → ${dest}"
}
