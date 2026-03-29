# mInstaller

A modular, extensible Bash-based installer framework for Kali Linux penetration-testing tools.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [CLI Usage](#cli-usage)
4. [Supported Modules](#supported-modules)
5. [How to Add a New Module](#how-to-add-a-new-module)
6. [Dry-Run Mode](#dry-run-mode)
7. [Noninteractive Mode](#noninteractive-mode)
8. [Caveats and Warnings](#caveats-and-warnings)
9. [File Listing](#file-listing)

---

## Overview

mInstaller automates the deployment of C-compiled penetration-testing utilities on Kali Linux. It handles:

- APT dependency installation (idempotent)
- Git repository cloning and updating
- Binary compilation via `make`
- Runtime directory layout creation with correct ownership and permissions
- Group, user, and sudoers provisioning
- Pre-installation conflict detection (port and service checks)

All operations are guarded by `set -euo pipefail`, explicit quoting, and idempotency checks. A dry-run mode lets you preview every action before committing.

---

## Architecture

```
mInstaller/
├── install.sh              # Main entrypoint — parse args, run modules
├── lib/
│   ├── log.sh              # Logging helpers (log_info, log_warn, log_error, die, …)
│   ├── apt.sh              # apt_update, apt_install (idempotent)
│   ├── git.sh              # git_clone_or_update
│   ├── system.sh           # User/group/dir/symlink/chmod/chown/setcap/sudoers
│   └── preflight.sh        # Root check, port/service conflict checks, OS check
├── modules/
│   ├── registry.sh         # Module manifest + source/validate helpers
│   ├── mcollector.sh       # mCollector installer module
│   └── mscreenshot.sh      # mScreenshot installer module
└── README.md               # This file
```

### Library Layer (`lib/`)

| File | Purpose |
|------|---------|
| `log.sh` | Colour-aware logging (`log_info`, `log_warn`, `log_error`, `log_step`, `log_dryrun`, `log_safety_warn`, `die`). Output goes to stderr. |
| `apt.sh` | `apt_update` (skips if cache is fresh), `apt_install` (skips already-installed packages). |
| `git.sh` | `git_clone_or_update` — clones if absent, pulls `--ff-only` if already present. |
| `system.sh` | `system_create_user`, `system_create_group`, `system_add_user_to_group`, `system_mkdir`, `system_symlink`, `system_chown`, `system_chmod`, `system_setcap`, `system_install_sudoers`, `system_copy_file`. |
| `preflight.sh` | `preflight_require_root`, `preflight_require_command`, `preflight_check_port_tcp/udp`, `preflight_check_service_conflict`, `preflight_warn_privileged_ports`, `preflight_check_disk_space`, `preflight_check_os`. |

### Module Layer (`modules/`)

Each module file must export:
- `module_<id>_preflight()` *(optional)* — safety checks, run before any changes.
- `module_<id>_install()` *(required)* — performs the actual installation.

The registry (`modules/registry.sh`) maps module IDs to files and human-readable metadata. `install.sh` sources modules on demand, so unused modules carry zero overhead.

---

## CLI Usage

```
sudo ./install.sh [OPTIONS] <module> [<module> ...]
sudo ./install.sh [OPTIONS] all
sudo ./install.sh          # no args → interactive numbered menu
```

### Interactive Menu

Running `./install.sh` with no module arguments launches a numbered selection menu:

```
  Select module(s) to install:

   1) mCollector         NTLMv2 hash capture via rogue SMB2/mDNS/HTTPS server ...
   2) mScreenshot        Full-port nmap scanner with headless Chromium screenshots ...
   3) all                Install all modules
   4) quit               Exit without installing

  Enter number(s) [1-4]:
```

You can enter a single number (`2`) or multiple numbers separated by spaces or commas (`1 2` or `1,2`). Selecting **all** installs every registered module; **quit** exits cleanly.

The menu is built dynamically from the module registry, so newly added modules appear automatically.

### Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help |
| `-l`, `--list` | List registered modules |
| `-n`, `--dry-run` | Preview all actions without making changes |
| `-y`, `--noninteractive` | Assume yes to all prompts; defaults to `all` when no module is specified |
| `-v`, `--verbose` | Enable debug logging |
| `-V`, `--version` | Print version |

### Examples

```bash
# Launch interactive menu (no arguments)
sudo ./install.sh

# Install all registered modules
sudo ./install.sh all

# Install mCollector only
sudo ./install.sh mcollector

# Install mScreenshot only
sudo ./install.sh mscreenshot

# Install both (explicit order)
sudo ./install.sh mcollector mscreenshot

# Preview without changes
sudo ./install.sh --dry-run all

# Fully automated (no prompts), verbose
sudo ./install.sh --noninteractive --verbose all

# Automated — no module given, defaults to 'all'
sudo ./install.sh --noninteractive

# List available modules
./install.sh --list
```

---

## Supported Modules

### `mcollector`

**mCollector** — C-based NTLMv2 hash capture tool (rogue SMB2, mDNS/LLMNR responder, HTTPS file server).

**What the installer does:**
1. Installs `build-essential`, `libssl-dev`, `git` via apt.
2. Clones `https://github.com/cMardikas/mCollector.git` → `/opt/mCollector/src`.
3. Builds with `make clean && make`.
4. Creates runtime layout:
   - `/opt/mCollector/mCollector` — compiled binary
   - `/opt/mCollector/etc/tls/` — optional custom TLS cert/key location
   - `/opt/mCollector/www/` — `index.html` and `mCollector.ps1`
   - `/opt/mCollector/data/` — working directory for manual runs
   - `/opt/mCollector/data/uploads/` — hash capture output
5. Symlinks `index.html` and `mCollector.ps1` into `/opt/mCollector/data/`.
6. Creates system user `mcollector` (nologin).
7. Sets `cap_net_bind_service` on the binary.
8. Finishes with manual run guidance only. It does not register a service.

**Preflight checks:**
- Warns about `systemd-resolved` (LLMNR port 5355), `smbd`/`nmbd` (SMB port 445), `avahi-daemon` (mDNS port 5353), `apache2`/`nginx` (HTTP/HTTPS ports 80/443).
- Warns about privileged ports (< 1024 — requires root or capabilities).
- Does **not** automatically stop or disable conflicting services. If a conflict is detected, it prints a safety warning and leaves resolution to the operator.

**Post-install manual steps:**
```bash
# If conflicts were reported, resolve them first, e.g.:
sudo systemctl stop avahi-daemon smbd nmbd apache2 nginx
# Then run mCollector manually:
cd /opt/mCollector/data
sudo /opt/mCollector/mCollector
# To clear captured uploads:
sudo /opt/mCollector/mCollector --clear
```

---

### `mscreenshot`

**mScreenshot** — C orchestrator wrapping nmap + headless Chromium + Selenium for full-port scanning with Bootstrap HTML reports.

**What the installer does:**
1. Installs `build-essential`, `nmap`, `xsltproc`, `chromium`, `chromium-driver`, `python3`, `python3-selenium` via apt.
2. Clones `https://github.com/cMardikas/mScreenshot.git` → `/opt/mScreenshot/src`.
3. Builds with `make`.
4. Sets ownership `root:mscreenshot` and permissions per deployment notes.
5. Creates `/opt/mScreenshot/reports/` with setgid bit (2770).
6. Creates system group `mscreenshot`.
7. Offers (interactively or via `--noninteractive`) to add the invoking user to the group.
8. Offers to install `/etc/sudoers.d/mscreenshot` (passwordless `sudo` for group members).
9. Copies the built binary to `/opt/mScreenshot/mScreenshot` and symlinks it to `/usr/local/bin/mscreenshot`.
10. Patches `/usr/bin/chromium` symlink if the binary is under a different name.
11. Installs a scan wrapper script at `/opt/mScreenshot/run-scan.sh`.
12. Finishes with manual run guidance only. It does not register a service or timer.

**Post-install usage:**
```bash
# Basic scan
cd /opt/mScreenshot/reports
sudo mscreenshot -d "test" 10.1.0.1

# Using the wrapper (edit targets in run-scan.sh first)
sudo /opt/mScreenshot/run-scan.sh
```

---

## How to Add a New Module

1. **Create the module file** at `modules/<name>.sh`:

```bash
#!/usr/bin/env bash
# modules/<name>.sh — Install <ToolName>
#
# Requires: lib/{log,apt,git,system,preflight}.sh sourced.

# Constants
_TOOL_OPT_DIR="/opt/<name>"

# Optional: preflight checks
module_<name>_preflight() {
    log_step "<ToolName> — Preflight"
    preflight_require_root
    # ... add checks
}

# Required: installation steps
module_<name>_install() {
    log_step "<ToolName> — Installation"
    apt_install build-essential git
    git_clone_or_update "https://github.com/example/<name>.git" "${_TOOL_OPT_DIR}/src"
    # ... build, layout, service, etc.
    log_ok "<ToolName> installation complete."
}
```

2. **Register the module** in `modules/registry.sh`:

```bash
# Add to MINSTALLER_MODULES array:
MINSTALLER_MODULES=(
    mcollector
    mscreenshot
    <name>          # <-- add here
)

# Add metadata:
MODULE_<name>_NAME="<ToolName>"
MODULE_<name>_DESC="One-line description"
MODULE_<name>_FILE="modules/<name>.sh"
```

3. **Test with dry-run:**

```bash
./install.sh --dry-run <name>
```

That's all. No changes to `install.sh` or any other file are required.

---

## Dry-Run Mode

Activate with `--dry-run` or `-n`. In dry-run mode:

- All library functions print what they **would** do instead of executing.
- apt commands, git operations, file writes, chown/chmod, setcap, sudoers fragments, and systemd unit installations are all skipped.
- Systemd service disable/enable calls are printed, not executed.
- The dry-run output can be used as a human-readable change plan.

**Dry-run does not guarantee 100% parity with a real run** for conditional branches that depend on live system state (e.g., whether a package is already installed). Run with `--dry-run --verbose` to see maximum detail.

---

## Noninteractive Mode

Activate with `--noninteractive` or `-y`. In this mode:

- All yes/no prompts are answered "yes" automatically.
- **If no module is specified**, installation defaults to `all` — the interactive menu is suppressed entirely.
- Suitable for automated deployment pipelines, provisioning scripts, or Ansible tasks.
- The user addition to `mscreenshot` group and the sudoers installation proceed automatically.

```bash
# These are equivalent in noninteractive mode:
sudo ./install.sh --noninteractive
sudo ./install.sh --noninteractive all
```

---

## Caveats and Warnings

### Conflicting services (mCollector)
mCollector binds ports that are also used by common Kali services. The installer detects conflicts and warns but **does not stop or disable** any service without explicit operator action. This protects operators who may have those services intentionally configured. Resolve conflicts manually before running mCollector.

### Privileged ports
mCollector binds ports 80, 443, 445, 5353, and 5355 — all below 1024. The installer sets `CAP_NET_BIND_SERVICE` on the binary so it can run under a dedicated `mcollector` user. Alternatively, run it as root.

### mScreenshot requires root at runtime
mScreenshot calls nmap with raw socket (SYN scan) mode, which requires root privileges. The binary performs a `getuid()==0` check and exits if not run as root. The sudoers fragment installed by mInstaller allows group members to run it without a password.

### No authentication on the mCollector web UI
The HTTPS server on port 443 has no authentication. Restrict access with firewall rules or bind only to a controlled interface.

### OpenSSL version
mCollector links against `libssl`/`libcrypto` (whichever version is installed). On Kali rolling this is typically OpenSSL 3.x. If build errors occur, check `apt list --installed | grep libssl`.

### Chromium / Selenium version skew
Always use the Kali apt packages (`chromium`, `chromium-driver`, `python3-selenium`) from the same release. Mixing apt Chromium with pip Selenium can cause version mismatches and silent failures.

### Hash file unbounded growth
`/opt/mCollector/data/uploads/hashes.txt` is append-only with in-memory deduplication per run only. For long engagements, monitor size and rotate manually.

### This framework installs to `/opt` and `/etc`
All installations write to system directories and require root. Do not run `install.sh` as an unprivileged user without `--dry-run`.
