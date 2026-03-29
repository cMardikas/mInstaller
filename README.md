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
│   ├── system.sh           # Directory/symlink/chmod/chown/setcap helpers
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
| `system.sh` | `system_mkdir`, `system_symlink`, `system_chown`, `system_chmod`, `system_setcap`, `system_copy_file` and related filesystem helpers. |
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
4. Creates a flat runtime layout under `/opt/mCollector` with only `src/` as a subfolder:
   - `/opt/mCollector/mCollector` — compiled binary
   - `/opt/mCollector/index.html` — web UI file
   - `/opt/mCollector/mCollector.ps1` — collector script
   - `/opt/mCollector/uploads/` — hash capture output
   - `/opt/mCollector/cert.pem` and `/opt/mCollector/key.pem` — optional TLS materials if you add them manually
5. Sets basic file permissions without creating any system user.
6. Sets `cap_net_bind_service` on the binary.
7. Finishes with manual run guidance only. It does not register a service.

**Preflight checks:**
- Warns about `systemd-resolved` (LLMNR port 5355), `smbd`/`nmbd` (SMB port 445), `avahi-daemon` (mDNS port 5353), `apache2`/`nginx` (HTTP/HTTPS ports 80/443).
- Warns about privileged ports (< 1024 — requires root or capabilities).
- Does **not** automatically stop or disable conflicting services. If a conflict is detected, it prints a safety warning and leaves resolution to the operator.

**Post-install manual steps:**
```bash
# If conflicts were reported, resolve them first, e.g.:
sudo systemctl stop avahi-daemon smbd nmbd apache2 nginx
# Then run mCollector manually:
cd /opt/mCollector
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
4. Creates a flat runtime layout under `/opt/mScreenshot` with only `src/` as a subfolder.
5. Copies the built binary to `/opt/mScreenshot/mScreenshot`.
6. Copies `scripts/` and `nmap-bootstrap.xsl` out of `src` into the install root.
7. Creates `/opt/mScreenshot/reports/` for output.
8. Symlinks the binary to `/usr/local/bin/mscreenshot`.
9. Patches `/usr/bin/chromium` symlink if the binary is under a different name.
10. Finishes with manual run guidance only. It does not register a service or timer.

**Post-install usage:**
```bash
# Basic scan
cd /opt/mScreenshot/reports
sudo mscreenshot -d "test" 10.1.0.1
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
- apt commands, git operations, file writes, chmod/chown, symlink creation, and setcap operations are all skipped.
- Destructive or system-changing actions are printed, not executed.
- The dry-run output can be used as a human-readable change plan.

**Dry-run does not guarantee 100% parity with a real run** for conditional branches that depend on live system state (e.g., whether a package is already installed). Run with `--dry-run --verbose` to see maximum detail.

---

## Noninteractive Mode

Activate with `--noninteractive` or `-y`. In this mode:

- Any remaining yes/no prompts are answered automatically.
- **If no module is specified**, installation defaults to `all` — the interactive menu is suppressed entirely.
- Suitable for automated deployment pipelines, provisioning scripts, or Ansible tasks.

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
mCollector binds ports 80, 443, 445, 5353, and 5355 — all below 1024. The installer sets `CAP_NET_BIND_SERVICE` on the binary where available. Alternatively, run it as root.

### mScreenshot requires root at runtime
mScreenshot calls nmap with raw socket (SYN scan) mode, which requires root privileges. The binary performs a `getuid()==0` check and exits if not run as root. Its required `scripts/` directory and `nmap-bootstrap.xsl` file are copied from `src` into `/opt/mScreenshot` during installation.

### No authentication on the mCollector web UI
The HTTPS server on port 443 has no authentication. Restrict access with firewall rules or bind only to a controlled interface.

### OpenSSL version
mCollector links against `libssl`/`libcrypto` (whichever version is installed). On Kali rolling this is typically OpenSSL 3.x. If build errors occur, check `apt list --installed | grep libssl`.

### Chromium / Selenium version skew
Always use the Kali apt packages (`chromium`, `chromium-driver`, `python3-selenium`) from the same release. Mixing apt Chromium with pip Selenium can cause version mismatches and silent failures.

### Hash file unbounded growth
`/opt/mCollector/uploads/hashes.txt` is append-only with in-memory deduplication per run only. For long engagements, monitor size and rotate manually.

### This framework installs to `/opt`
All installations write to system directories and require root. Do not run `install.sh` as an unprivileged user without `--dry-run`.
