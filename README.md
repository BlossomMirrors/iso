# BlossomOS ISO Builder

[![Build Status](https://ci.blossomos.org/api/badges/2/status.svg)](https://ci.blossomos.org)

This repository builds bootable BlossomOS installation media using [Titanoboa](https://github.com/ublue-os/titanoboa) and the Anaconda installer with WebUI.

## Overview

BlossomOS ISO Builder creates installation media for [BlossomOS](https://blossomos.org), a beautiful KDE Plasma desktop built on Fedora Kinoite. These ISOs provide a live environment with the Anaconda WebUI installer for easy installation.

### Features

- **Live Environment**: Boots into a fully functional BlossomOS desktop
- **Anaconda WebUI Installer**: Modern web-based installation experience
- **Multiple Flavors**: Support for standard and NVIDIA Open variants
- **Pre-configured**: Optimized BTRFS partitioning, secure boot support, flatpak integration
- **Test & Production Pipeline**: ISOs are built to test bucket, then promoted to production
- **Manual Promotion**: Controlled release process with dry-run capability

## Download

Pre-built ISOs are available at [blossomos.org](https://blossomos.org).

## Repository Structure

```
.
├── iso_files/
│   ├── configure_iso_anaconda-webui.sh     # ISO configuration script
│   └── scope_installer.png                 # Installer branding
├── .pre-commit-config.yaml                 # Pre-commit hooks
├── Justfile                                # Build automation recipes
└── README.md                               # This file
```

The flatpak list for the live environment is fetched directly from the [image repo](https://dev.blossomos.org/blossom/os/core/image) at build time.

## Building ISOs

### Prerequisites

ISOs are built using CI, but you can validate your changes locally:

```bash
# Install Just command runner
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"

# Install pre-commit
pip install pre-commit
pre-commit install
```

### Validation

```bash
# Check all syntax and formatting
pre-commit run --all-files

# Validate Justfile syntax
just check

# Test ISO configuration script
just test-iso-config

# Auto-fix formatting issues
just fix
```

### Available Just Recipes

```bash
# List all available recipes
just --list

# Clean build artifacts
just clean

# Generate flatpak list from the image repo
just generate-flatpak-list

# Get image name for specific combination
just image_name blossomos stable main

# Validate image/tag/flavor combination
just validate blossomos stable nvidia-open
```

## ISO Variants

### Flavors

- **main**: Standard BlossomOS ISO with open-source drivers
- **nvidia-open**: BlossomOS ISO with NVIDIA Open kernel modules

### Versions

- **stable**: Latest stable Fedora release (recommended)
- **latest**: Current Fedora release (in-development packages)

## Configuration

### ISO Customization

The ISO is customized via `iso_files/configure_iso_anaconda-webui.sh`:

- Installs Anaconda WebUI installer
- Configures BlossomOS-specific Anaconda profile
- Sets up BTRFS partitioning with zstd compression
- Adds installer to KDE panel and kickoff menu
- Configures secure boot key enrollment
- Pre-installs flatpaks (fetched from the image repo's `packages.flatpak` at build time)

### Anaconda Profile

The custom BlossomOS profile includes:

- **Storage**: BTRFS with zstd:1 compression
- **Partitioning**:
  - `/` (1 GiB min, 70 GiB max)
  - `/home` (500 MiB min, 50 GiB free)
  - `/var` (BTRFS)
- **Network**: First wired connection auto-enabled
- **Bootloader**: Fedora EFI directory, auto-hide menu

### Secure Boot

Secure boot is supported by default. After installation, users are prompted to enroll the secure boot key with password: `universalblue`

## Contributing

Contributions are welcome! Please follow these guidelines:

### Before Committing

1. Run validation: `just check && pre-commit run --all-files`
2. Test ISO script syntax: `just test-iso-config`
3. Use [conventional commits](https://www.conventionalcommits.org/en/v1.0.0/#specification)
4. Keep changes minimal and focused

### Common Changes

- **Branding**: Update images in `iso_files/`
- **Anaconda config**: Edit profile in `configure_iso_anaconda-webui.sh`
- **Flatpak lists**: Modify [`build_files/base/packages.flatpak`](https://dev.blossomos.org/blossom/os/core/image/-/raw/main/build_files/base/packages.flatpak) in the image repo
- **Partitioning**: Modify `default_partitioning` in the Anaconda profile

## Documentation

- [BlossomOS Documentation](https://docs.blossomos.org)
- [BlossomOS Community](https://community.blossomos.org)
- [Titanoboa](https://github.com/ublue-os/titanoboa) — ISO builder tool
- [Image Repository](https://dev.blossomos.org/blossom/os/core/image) — OCI image source

## Resources

- [BlossomOS Website](https://blossomos.org)
- [BlossomOS Image Repository](https://dev.blossomos.org/blossom/os/core/image)
- [Universal Blue](https://universal-blue.org)

## License

Apache-2.0
