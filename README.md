# mInstaller

Installer for deploying supported tools on Kali Linux.

## Get it

```bash
git clone https://github.com/cMardikas/mInstaller.git
cd mInstaller
chmod +x mInstaller.sh
```

## Run it

When run from its git checkout, `mInstaller` automatically checks its own repository, fast-forwards from `origin/main` if needed, and then continues.

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

Show help:

```bash
./mInstaller.sh --help
```
