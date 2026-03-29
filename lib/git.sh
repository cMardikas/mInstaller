#!/usr/bin/env bash
# lib/git.sh — Git repository clone / update helpers for mInstaller
#
# Requires: lib/log.sh sourced first.
# Globals read: DRY_RUN (0/1)

# ---------------------------------------------------------------------------
# git_clone_or_update <repo_url> <dest_dir>
#
#   If <dest_dir>/.git exists  → fetch + fast-forward on the default branch.
#   Otherwise                  → clone into <dest_dir>.
#
#   Parent directory of <dest_dir> must already exist (or be root-owned;
#   the caller is responsible for mkdir -p).
# ---------------------------------------------------------------------------
git_clone_or_update() {
    local repo_url="${1:?git_clone_or_update: missing repo URL}"
    local dest_dir="${2:?git_clone_or_update: missing destination directory}"

    if [[ -d "${dest_dir}/.git" ]]; then
        log_info "Repository already cloned at ${dest_dir}; pulling latest..."
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            log_dryrun "[git] git -C '${dest_dir}' pull --ff-only"
            return 0
        fi
        git -C "${dest_dir}" fetch --quiet origin \
            || { log_warn "git fetch failed; continuing with existing checkout"; return 0; }
        git -C "${dest_dir}" pull --ff-only --quiet \
            || log_warn "git pull --ff-only failed (diverged history?); leaving as-is"
        log_ok "Repository updated: ${dest_dir}"
    else
        log_info "Cloning ${repo_url} → ${dest_dir} ..."
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            log_dryrun "[git] git clone '${repo_url}' '${dest_dir}'"
            return 0
        fi
        git clone --quiet "${repo_url}" "${dest_dir}" \
            || die "git clone failed: ${repo_url} → ${dest_dir}"
        log_ok "Repository cloned: ${dest_dir}"
    fi
}

# ---------------------------------------------------------------------------
# git_clone_or_update_as_root <repo_url> <dest_dir>
#
#   Wrapper that forces the git operations to be performed as root.
#   Useful when <dest_dir> is owned by root and the installer runs as root.
#   (On Kali penetration-testing installs, running as root is typical.)
# ---------------------------------------------------------------------------
git_clone_or_update_as_root() {
    # When already root this is identical to git_clone_or_update.
    git_clone_or_update "$@"
}
