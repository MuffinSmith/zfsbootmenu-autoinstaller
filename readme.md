# ZFSBootMenu Installation Script

This script automates the installation and configuration of a headless ZFSBootMenu system from a supported live installation environment. It now supports these matching live-target pairs:

- Debian live -> Debian target
- Fedora Server installer -> Fedora target

## Prerequisites

- A supported live installation environment
- A disk available for partitioning and installation (existing data will be erased)
- Network connection for downloading packages and files

## Features

- Auto-detects Debian live versus Fedora Server installer environments
- Preserves the existing Debian installation flow
- Builds a headless target with systemd-networkd and OpenSSH
- Creates and configures ZFS partitions and filesystems
- Sets up ZFSBootMenu for EFI boot
- Adds a user with sudo privileges and configures the system for basic usage

## Usage

1. **Choose a supported live environment**
   Debian live installs Debian.
   Fedora Server installer installs Fedora.

2. **Run the script from the live environment**
   For manual testing on this branch, fetch the script from `feature/fedora-support`.

   Debian live:

   ```bash
   sudo su # switches to root
   apt update
   apt upgrade
   apt install curl
   curl -fsSLo setup-zfsbootmenu.sh https://raw.githubusercontent.com/MuffinSmith/zfsbootmenu-autoinstaller/feature/fedora-support/setup-zfsbootmenu.sh
   chmod +x setup-zfsbootmenu.sh
   ./setup-zfsbootmenu.sh
   ```

   Fedora Server installer shell:

   ```bash
   PKG_MANAGER="$(command -v dnf || command -v dnf5 || command -v microdnf)"
   [ -n "$PKG_MANAGER" ] || { echo "No Fedora package manager found"; exit 1; }
   timedatectl set-ntp true || true
   command -v curl >/dev/null 2>&1 || "$PKG_MANAGER" install -y curl
   curl -fsSLo setup-zfsbootmenu.sh https://raw.githubusercontent.com/MuffinSmith/zfsbootmenu-autoinstaller/feature/fedora-support/setup-zfsbootmenu.sh
   chmod +x setup-zfsbootmenu.sh
   ./setup-zfsbootmenu.sh
   ```

   Use `Ctrl`+`Alt`+`F2` from the installer UI to reach the shell if needed. The installer shell runs as `root`.

3. **Follow prompts**
   - The script will prompt you for:
     - **Username** and **password** for a new user
     - **Root password**
     - **Hostname**
     - **Disk selection** for the boot and pool partitions
     - **Optional first-boot wired network settings**

4. **Automatic steps**
   - The script will automatically:
     - Detect the live distro and choose the matching install path
     - Install required packages for the live environment and target system
     - Partition the selected disk
     - Create and configure ZFS pool and datasets
     - Set up a chroot environment
     - Install and configure ZFSBootMenu and EFI boot entries
     - Configure a headless system with systemd-networkd and OpenSSH
     - Perform cleanup

5. **Completion**
   - After running, the system is ready to reboot into the new ZFSBootMenu setup.

## Configuration

This script sets default variables for installation, including:

- `BOOT_DISK`: Device for the boot partition (default `/dev/nvme0n1`)
- `POOL_DISK`: Device for the ZFS pool (default `/dev/nvme0n1`)
- `POOL_NAME`: Name of the ZFS pool (default `zroot`)
- `KERNEL_VERSION`: The current kernel version, determined automatically
- `DEBIAN_RELEASE`: Debian target release used when booted from Debian live
- Fedora target release is auto-detected from the Fedora Server installer environment

You can modify these defaults directly in the script if needed.

## Important Notes

- **Warning**: This script will erase all data on the selected disk.
- **Compatibility**: Supported flows are Debian live -> Debian target and Fedora Server installer -> Fedora target.
- **Target profile**: Fedora installs are built minimally with `dnf --installroot`; no desktop environment is copied into the target and removed later.
- **Guide alignment**: The Fedora path intentionally diverges from the official ZFSBootMenu Workstation-live guide so the target starts as a minimal headless system.
- **Network**: Ensure a working internet connection, as the script will download packages.
- **Testing**: This branch is intended for manual hardware validation; VM testing was not performed in this workspace.

## BadUSB Helpers

- [InstallZFSBootMenuDebian.txt](InstallZFSBootMenuDebian.txt) boots Debian live and fetches the installer.
- [InstallZFSBootMenuFedora.txt](InstallZFSBootMenuFedora.txt) switches the Fedora Server installer to a shell and bootstraps the installer from `feature/fedora-support`.

## Troubleshooting

- **Permissions**: Run the script with `sudo` to ensure it has the necessary permissions.
- **Disk Selection**: If no suitable disks are shown, confirm your disks are properly detected (`lsblk` can help).

## License

This script is provided as-is. Feel free to modify and adapt it to suit your needs.
