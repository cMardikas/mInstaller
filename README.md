# mInstaller

Installer for deploying supported tools on Kali Linux.

## Get it

```bash
git clone https://github.com/cMardikas/mInstaller.git
cd mInstaller
chmod +x mInstaller.sh
```


## Run it

When run from its git checkout, `mInstaller` checks whether a newer version is available. To update it explicitly, run `sudo ./mInstaller.sh --self-update`.

Interactive menu:

```bash
sudo ./mInstaller.sh
```

Install everything:

```bash
sudo ./mInstaller.sh all
```

Install a specific module:

```bash
sudo ./mInstaller.sh mcollector
sudo ./mInstaller.sh mscreenshot
```

Preview only:

```bash
sudo ./mInstaller.sh --dry-run
sudo ./mInstaller.sh --dry-run all
```

Noninteractive:

```bash
sudo ./mInstaller.sh --noninteractive
sudo ./mInstaller.sh --noninteractive mcollector
sudo ./mInstaller.sh --noninteractive mscreenshot
```

List available modules:

```bash
./mInstaller.sh --list
```

Self-update:

```bash
sudo ./mInstaller.sh --self-update
```

Show help:

```bash
./mInstaller.sh --help
```

## mCollector runtime layout

After `mcollector` runs, `/opt/mCollector/` contains:

- `mCollector` — the built binary (index.html and mCollector.ps1 are embedded at build time).
- `koondraport.py` — operator-run fleet-report helper.
- `cert.pem` / `key.pem` — optional, operator-supplied TLS material.
- `uploads/` — captured data; never modified by the installer.
- `public/` — operator-supplied static downloads. mCollector >= 1.5.0 serves
  these at `/<filename>` (e.g. drop `PingCastle.exe` here and it is reachable
  at `https://<host>/PingCastle.exe`). The directory is preserved across
  upgrades.
- `src/` — build checkout, used for rebuilds.

On upgrade, the installer migrates legacy loose downloadable files (currently
`PingCastle.exe`) from `/opt/mCollector/` into `public/` when the destination
is empty. If both copies exist, the loose copy is left in place with a warning
so the operator can resolve it manually.
