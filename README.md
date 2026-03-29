# mInstaller

Installer for deploying supported tools on Kali Linux.

## Get it

```bash
git clone https://github.com/cMardikas/mInstaller.git
cd mInstaller
chmod +x install.sh
```

## Run it

Interactive menu:

```bash
sudo ./install.sh
```

Install everything:

```bash
sudo ./install.sh all
```

Install a specific module:

```bash
sudo ./install.sh mcollector
sudo ./install.sh mscreenshot
```

Preview only:

```bash
sudo ./install.sh --dry-run
sudo ./install.sh --dry-run all
```

Noninteractive:

```bash
sudo ./install.sh --noninteractive
sudo ./install.sh --noninteractive mcollector
sudo ./install.sh --noninteractive mscreenshot
```

List available modules:

```bash
./install.sh --list
```

Show help:

```bash
./install.sh --help
```