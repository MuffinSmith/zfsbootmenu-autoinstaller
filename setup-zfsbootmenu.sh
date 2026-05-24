#!/bin/bash

set -Eeo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# Automatically set other variables
DEBIAN_RELEASE="trixie"
BOOT_DISK="/dev/nvme0n1"
BOOT_PART="1"
POOL_DISK="/dev/nvme0n1"
POOL_PART="2"
POOL_NAME="zroot"
KERNEL_VERSION=$(uname -r)  # Automatically get current kernel version
MOUNT_POINT="/mnt"
ID=$(source /etc/os-release && echo "$ID")  # Get OS ID from /etc/os-release
DEBUG_LOG=""
SHARE_NAME="zfsbootmenu"
SHARE_USER="user"
SHARE_PASSWORD="password"
SMB_SHARE_DIR="/var/lib/zfsbootmenu-share"
SMB_READY="0"
SMB_IPS=""
SNAPSHOT_PACKAGE_ROOT="https://snapshot.debian.org/package/linux"

resolve_desktop_dir() {
	local target_user=""
	local target_home=""

	if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
		target_user="${SUDO_USER}"
	else
		target_user=$(logname 2>/dev/null || true)
	fi

	if [[ -n "$target_user" && "$target_user" != "root" ]]; then
		target_home=$(getent passwd "$target_user" | cut -d: -f6)
	fi

	if [[ -z "$target_home" ]]; then
		target_home="${HOME:-/root}"
	fi

	echo "${target_home}/Desktop"
}

setup_debug_logging() {
	local log_dir
	local timestamp

	log_dir=$(resolve_desktop_dir)
	if ! mkdir -p "$log_dir" 2>/dev/null; then
		log_dir="/tmp"
		mkdir -p "$log_dir"
	fi

	timestamp=$(date +%Y%m%d-%H%M%S)
	DEBUG_LOG="${log_dir}/zfsbootmenu-install-${timestamp}.log"
	: > "$DEBUG_LOG"
	chmod 0644 "$DEBUG_LOG" 2>/dev/null || true
	exec > >(tee -a "$DEBUG_LOG") 2>&1

	echo "Debug log: $DEBUG_LOG"
}

log_environment_snapshot() {
	echo "=== ZFSBootMenu installer debug context ==="
	echo "Start time: $(date -Iseconds 2>/dev/null || date)"
	echo "Target Debian release: $DEBIAN_RELEASE"
	echo "Live OS ID: $ID"
	echo "Live kernel: $KERNEL_VERSION"
	echo "Running as: $(id -un)"
	echo "Working directory: $(pwd)"
	echo "--- lsblk ---"
	lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
	echo "-------------"
}

log_selected_configuration() {
	echo "Selected boot disk: $BOOT_DISK"
	echo "Selected pool disk: $POOL_DISK"
	echo "Boot device: $BOOT_DEVICE"
	echo "Pool device: $POOL_DEVICE"
	echo "Pool name: $POOL_NAME"
	echo "Mount point: $MOUNT_POINT"
	echo "Hostname: $HOSTNAME"
	echo "Username: $USERNAME"
}

fetch_network_time() {
	local network_time=""

	if command -v curl >/dev/null 2>&1; then
		network_time=$(curl -fsI http://deb.debian.org/ 2>/dev/null | tr -d '\r' | awk 'BEGIN { IGNORECASE = 1 } /^Date:/ { sub(/^[^:]+: /, ""); print; exit }')
	elif command -v wget >/dev/null 2>&1; then
		network_time=$(wget -qSO- --spider http://deb.debian.org 2>&1 | tr -d '\r' | awk 'BEGIN { IGNORECASE = 1 } /^  Date:/ { sub(/^  Date: /, ""); print; exit }')
	fi

	echo "$network_time"
}

sync_system_clock() {
	local ntp_state=""
	local network_time=""

	echo "Checking live system clock..."
	echo "Current time before sync attempt: $(date -Iseconds 2>/dev/null || date)"

	if command -v hwclock >/dev/null 2>&1; then
		hwclock --hctosys 2>/dev/null || true
	fi

	if command -v timedatectl >/dev/null 2>&1; then
		timedatectl set-ntp true 2>/dev/null || true
		systemctl restart systemd-timesyncd 2>/dev/null || true

		for _ in 1 2 3 4 5; do
			ntp_state=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)
			if [[ "$ntp_state" == "yes" || "$ntp_state" == "true" ]]; then
				break
			fi
			sleep 2
		done

		echo "timedatectl status after sync attempt:"
		timedatectl status 2>/dev/null || true
	else
		echo "timedatectl not available; skipping NTP sync attempt."
	fi

	ntp_state=${ntp_state:-$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)}
	if [[ "$ntp_state" != "yes" && "$ntp_state" != "true" ]]; then
		network_time=$(fetch_network_time)
		if [[ -n "$network_time" ]]; then
			echo "Applying fallback network time from deb.debian.org: $network_time"
			date -u -s "$network_time" >/dev/null
		else
			echo "Unable to obtain fallback network time; continuing with current clock."
		fi
	fi

	echo "Current time after sync attempt: $(date -Iseconds 2>/dev/null || date)"
}

get_local_ipv4_addresses() {
	hostname -I 2>/dev/null | awk '{
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i != "127.0.0.1") {
				print $i
			}
		}
	}'
}

print_smb_access_details() {
	local ip

	if [[ -z "$SMB_IPS" ]]; then
		SMB_IPS=$(get_local_ipv4_addresses | paste -sd ' ' -)
	fi

	if [[ -z "$SMB_IPS" ]]; then
		echo "Unable to determine a non-loopback IPv4 address for this live system."
		return
	fi

	echo "SMB share credentials: ${SHARE_USER}/${SHARE_PASSWORD}"
	for ip in $SMB_IPS; do
		echo "SMB log share: \\\\${ip}\\${SHARE_NAME}"
		echo "Windows path: \\\\${ip}\\${SHARE_NAME}"
	done
}

ensure_share_user() {
	if ! id "$SHARE_USER" >/dev/null 2>&1; then
		useradd -M -s /usr/sbin/nologin "$SHARE_USER"
	fi

	printf '%s\n%s\n' "$SHARE_PASSWORD" "$SHARE_PASSWORD" | smbpasswd -a -s "$SHARE_USER" >/dev/null
	smbpasswd -e "$SHARE_USER" >/dev/null
}

write_samba_config() {
	cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server role = standalone server
   map to guest = Never
   obey pam restrictions = no
   pam password change = no
   passwd program = /usr/bin/passwd %u
   unix password sync = no
   log file = /var/log/samba/log.%m
   max log size = 1000
   server min protocol = SMB2

[${SHARE_NAME}]
   path = ${SMB_SHARE_DIR}
   browseable = yes
   read only = yes
   guest ok = no
   valid users = ${SHARE_USER}
EOF
}

start_samba_service() {
	pkill smbd 2>/dev/null || true

	if command -v systemctl >/dev/null 2>&1; then
		systemctl restart smbd 2>/dev/null || systemctl start smbd 2>/dev/null || true
	fi

	if ! pgrep smbd >/dev/null 2>&1; then
		smbd -D >/dev/null 2>&1 || return 1
	fi

	pgrep smbd >/dev/null 2>&1
}

publish_debug_log_over_smb() {
	local install_rc=0

	if [[ -z "$DEBUG_LOG" || ! -f "$DEBUG_LOG" || "$SMB_READY" == "1" ]]; then
		return
	fi

	echo "Preparing SMB log share for Windows access..."
	mkdir -p "$SMB_SHARE_DIR"
	cp -f "$DEBUG_LOG" "$SMB_SHARE_DIR/"
	ln -sfn "$DEBUG_LOG" "$SMB_SHARE_DIR/latest.log"
	chmod 0755 "$SMB_SHARE_DIR"
	chmod 0644 "$SMB_SHARE_DIR"/* 2>/dev/null || true

	if ! command -v smbd >/dev/null 2>&1 || ! command -v smbpasswd >/dev/null 2>&1; then
		echo "Installing Samba packages for log sharing..."
		set +e
		apt-get update
		apt-get install -y samba
		install_rc=$?
		set -e
		if [[ $install_rc -ne 0 ]]; then
			echo "Unable to install Samba packages automatically."
			return
		fi
	fi

	ensure_share_user || return
	write_samba_config
	if start_samba_service; then
		SMB_READY="1"
		SMB_IPS=$(get_local_ipv4_addresses | paste -sd ' ' -)
		echo "SMB log sharing is ready."
		print_smb_access_details
	else
		echo "Failed to start the Samba service for log sharing."
	fi
}

download_file() {
	local url="$1"
	local output_path="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$output_path"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$output_path" "$url"
	else
		echo "Neither curl nor wget is available to download $url"
		return 1
	fi
}

fetch_snapshot_page() {
	local source_version="$1"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "${SNAPSHOT_PACKAGE_ROOT}/${source_version}/"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO- "${SNAPSHOT_PACKAGE_ROOT}/${source_version}/"
	else
		return 1
	fi
}

extract_snapshot_package_url() {
	local snapshot_page="$1"
	local package_pattern="$2"
	local package_url=""

	package_url=$(printf '%s\n' "$snapshot_page" | grep -oE "(https://snapshot\.debian\.org)?/archive/debian/[^"]*/${package_pattern}" | head -n1 || true)

	case "$package_url" in
		https://snapshot.debian.org/*)
			printf '%s\n' "$package_url"
			;;
		/archive/*)
			printf '%s\n' "https://snapshot.debian.org${package_url}"
			;;
	esac

	return 0
}

install_live_kernel_headers_from_snapshot() {
	local kernel_release_base="${KERNEL_VERSION%%+*}"
	local source_version="${kernel_release_base}-1"
	local host_arch=""
	local kernel_abi=""
	local escaped_kernel_version="${KERNEL_VERSION//+/%2B}"
	local escaped_kernel_abi=""
	local snapshot_page=""
	local temp_dir=""
	local headers_url=""
	local common_url=""
	local kbuild_url=""

	host_arch=$(dpkg --print-architecture)
	kernel_abi="${KERNEL_VERSION%-${host_arch}}"
	escaped_kernel_abi="${kernel_abi//+/%2B}"

	echo "Attempting to install exact live kernel headers for $KERNEL_VERSION from Debian snapshot..."
	snapshot_page=$(fetch_snapshot_page "$source_version") || {
		echo "Unable to retrieve Debian snapshot metadata for $source_version"
		return 1
	}

	headers_url=$(extract_snapshot_package_url "$snapshot_page" "linux-headers-${escaped_kernel_version}_${source_version}_${host_arch}\.deb")
	common_url=$(extract_snapshot_package_url "$snapshot_page" "linux-headers-${escaped_kernel_abi}-common_${source_version}_all\.deb")
	kbuild_url=$(extract_snapshot_package_url "$snapshot_page" "linux-kbuild-${escaped_kernel_abi}_${source_version}_${host_arch}\.deb")

	if [[ -z "$headers_url" || -z "$common_url" || -z "$kbuild_url" ]]; then
		echo "Unable to find Debian snapshot packages for the running live kernel $KERNEL_VERSION"
		return 1
	fi

	temp_dir=$(mktemp -d)
	download_file "$common_url" "$temp_dir/common.deb"
	download_file "$kbuild_url" "$temp_dir/kbuild.deb"
	download_file "$headers_url" "$temp_dir/headers.deb"
	apt-get install -y "$temp_dir"/*.deb
	rm -rf "$temp_dir"
}

prepare_host_efi_support() {
	echo "Checking EFI variable access..."
	if [[ -d /sys/firmware/efi/efivars ]]; then
		echo "EFI variables are already available."
		return
	fi

	mkdir -p /sys/firmware/efi/efivars 2>/dev/null || true
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true

	if [[ -d /sys/firmware/efi/efivars ]]; then
		echo "EFI variables are available."
	else
		echo "EFI variables are not mounted yet; the chroot phase will mount efivarfs before creating boot entries."
	fi
}

install_live_kernel_headers() {
	local header_package="linux-headers-$KERNEL_VERSION"

	echo "Installing live kernel headers..."
	if apt-cache show "$header_package" >/dev/null 2>&1; then
		apt-get install -y "$header_package"
	else
		echo "Live kernel header package $header_package is not available in the current repositories."
		install_live_kernel_headers_from_snapshot
	fi
}

log_error() {
	local line_no="$1"
	local exit_code="$2"

	echo "ERROR: command failed at line ${line_no} with exit code ${exit_code}"
	if [[ -n "$DEBUG_LOG" ]]; then
		echo "Debug log saved to: $DEBUG_LOG"
	fi
}

log_exit() {
	local exit_code=$?

	if [[ -n "$DEBUG_LOG" ]]; then
		if [[ $exit_code -eq 0 ]]; then
			echo "Debug log saved to: $DEBUG_LOG"
		else
			publish_debug_log_over_smb
			print_smb_access_details
			echo "Installer failed. Debug log saved to: $DEBUG_LOG"
		fi
	fi
}

trap 'log_error $LINENO $?' ERR
trap 'log_exit' EXIT

partition_device() {
	local disk="$1"
	local part="$2"

	if [[ "$disk" =~ [0-9]$ ]]; then
		echo "${disk}p${part}"
	else
		echo "${disk}${part}"
	fi
}

refresh_device_vars() {
	BOOT_DEVICE=$(partition_device "$BOOT_DISK" "$BOOT_PART")
	POOL_DEVICE=$(partition_device "$POOL_DISK" "$POOL_PART")
}

get_username_and_password(){
  # Prompt user for variables
  read -p "Enter username for the new user: " USERNAME
  read -sp "Enter password for the new user: " USER_PASSWORD
  echo
  read -sp "Enter root password: " ROOT_PASSWORD
  echo
  read -p "Enter hostname for this system: " HOSTNAME
}

select_disk() {
  echo "Available disks:"
  # List available disks with lsblk and store them in an array
  mapfile -t disks < <(lsblk -dn -o NAME,SIZE,TYPE | grep 'disk')

  # Display disks with numbering
  for i in "${!disks[@]}"; do
    echo "$((i + 1)). ${disks[i]}"
  done

  # Prompt user to select a disk by number
  while true; do
    read -p "Enter the number of the disk you want to use for boot and pool (e.g., 1, 2): " choice
    if [[ $choice -gt 0 && $choice -le ${#disks[@]} ]]; then
      # Get the selected disk name (e.g., 'sda' from 'sda 500G disk')
      selected_disk=$(echo "${disks[$((choice - 1))]}" | awk '{print $1}')
      BOOT_DISK="/dev/$selected_disk"
      POOL_DISK="/dev/$selected_disk"
			refresh_device_vars
      echo "Selected disk: $BOOT_DISK"
      break
    else
      echo "Invalid choice. Please select a number from the list."
    fi
  done
  echo "Boot Disk is set to $BOOT_DISK"
  echo "Pool Disk is set to $POOL_DISK"
}




# Functions
generate_hostid() {
  echo "Generating host ID..."
  zgenhostid -f 0x00bab10c
}

configure_apt_sources() {
  echo "Configuring APT sources..."
  cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${DEBIAN_RELEASE} main contrib non-free-firmware
deb-src http://deb.debian.org/debian ${DEBIAN_RELEASE} main contrib non-free-firmware

deb http://deb.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free-firmware
deb-src http://deb.debian.org/debian-security/ ${DEBIAN_RELEASE}-security main contrib non-free-firmware

deb http://deb.debian.org/debian ${DEBIAN_RELEASE}-updates main contrib non-free-firmware
deb-src http://deb.debian.org/debian ${DEBIAN_RELEASE}-updates main contrib non-free-firmware
EOF
}

install_host_packages() {
  echo "Installing necessary packages"
	apt-get update
	apt-get install -y debootstrap gdisk dkms curl
	install_live_kernel_headers
	apt-get install -y dosfstools efibootmgr zfsutils-linux
	echo "Loading ZFS module for the live environment"
	modprobe zfs
	prepare_host_efi_support
}

partition_disk() {
  echo "Partitioning disk $POOL_DISK..."
	zpool labelclear -f "$POOL_DISK" 2>/dev/null || true
	wipefs -a "$POOL_DISK"
	if [[ "$BOOT_DISK" != "$POOL_DISK" ]]; then
		wipefs -a "$BOOT_DISK"
	fi

	sgdisk --zap-all "$POOL_DISK"
	if [[ "$BOOT_DISK" != "$POOL_DISK" ]]; then
		sgdisk --zap-all "$BOOT_DISK"
	fi

	sgdisk -n"${BOOT_PART}":1M:+512M -t"${BOOT_PART}":EF00 "$BOOT_DISK"
	sgdisk -n"${POOL_PART}":0:-10M -t"${POOL_PART}":BF00 "$POOL_DISK"
}

create_zpool() {
  echo "Creating ZFS pool and datasets..."
	zpool create -f -o ashift=12 -O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on -o autotrim=on -o compatibility=openzfs-2.2-linux -m none "$POOL_NAME" "$POOL_DEVICE"
	zfs create -o mountpoint=none "$POOL_NAME/ROOT"
	zfs create -o mountpoint=/ -o canmount=noauto "$POOL_NAME/ROOT/$ID"
	zfs create -o mountpoint=/home "$POOL_NAME/home"
	zpool set bootfs="$POOL_NAME/ROOT/$ID" "$POOL_NAME"
}

export_import_zpool() {
  echo "Exporting and re-importing ZFS pool for mounting..."
	zpool export "$POOL_NAME"
	zpool import -N -R "$MOUNT_POINT" "$POOL_NAME"
	zfs mount "$POOL_NAME/ROOT/$ID"
	zfs mount "$POOL_NAME/home"
	udevadm trigger
}

setup_base_system() {
  echo "Installing base system with debootstrap..."
	debootstrap "$DEBIAN_RELEASE" "$MOUNT_POINT"
	cp /etc/hostid "$MOUNT_POINT/etc/hostid"
	cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"
}

prepare_chroot() {
  echo "Mounting filesystems for chroot environment..."
  mount -t proc proc $MOUNT_POINT/proc
  mount -t sysfs sys $MOUNT_POINT/sys
  mount -B /dev $MOUNT_POINT/dev
  mount -t devpts pts $MOUNT_POINT/dev/pts
}

enter_chroot() {
	echo "Entering chroot environment to configure system..."
	chroot $MOUNT_POINT /bin/bash <<-EOF
	set -Eeo pipefail

	chroot_log_error() {
		local line_no="\$1"
		local exit_code="\$2"
		echo "[chroot] ERROR: command failed at line \${line_no} with exit code \${exit_code}"
	}

	trap 'chroot_log_error \$LINENO \$?' ERR

	# Set hostname
	echo "$HOSTNAME" > /etc/hostname
	echo "127.0.1.1    $HOSTNAME" >> /etc/hosts
	
	# Configure apt sources
		cat > /etc/apt/sources.list <<-EOF_APT
		deb http://deb.debian.org/debian ${DEBIAN_RELEASE} main contrib non-free-firmware
		deb-src http://deb.debian.org/debian ${DEBIAN_RELEASE} main contrib non-free-firmware
		
		deb http://deb.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free-firmware
		deb-src http://deb.debian.org/debian-security/ ${DEBIAN_RELEASE}-security main contrib non-free-firmware
		
		deb http://deb.debian.org/debian ${DEBIAN_RELEASE}-updates main contrib non-free-firmware
		deb-src http://deb.debian.org/debian ${DEBIAN_RELEASE}-updates main contrib non-free-firmware
		EOF_APT
	
	# Update and install necessary packages
	export DEBIAN_FRONTEND=noninteractive
	apt update
	apt install -y locales keyboard-configuration console-setup
	apt install -y linux-headers-amd64 linux-image-amd64 zfs-initramfs dosfstools efibootmgr curl
	
	echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf
	
	# Install system utilities
	echo "Installing system utilities..."
	apt install -y systemd-timesyncd net-tools iproute2 isc-dhcp-client iputils-ping traceroute curl wget dnsutils ethtool ifupdown tcpdump nmap nano vim htop openssh-server git tmux
	
	# Set locale and timezone
	echo "Configuring locale and timezone..."
	echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
	locale-gen
	dpkg-reconfigure -f noninteractive tzdata
	
	# Set root password
	echo "Setting root password..."
	echo "root:$ROOT_PASSWORD" | chpasswd
	
	# Create user and set password
	echo "Creating user and setting permissions..."
	useradd -m -s /bin/bash -G sudo,audio,cdrom,dip,floppy,netdev,plugdev,video $USERNAME
	echo "$USERNAME:$USER_PASSWORD" | chpasswd
	
	# Enable systemd ZFS services
	echo "Enabling systemd ZFS services..."
	systemctl enable zfs.target
	systemctl enable zfs-import-cache
	systemctl enable zfs-mount
	systemctl enable zfs-import.target
	
	# Rebuild initramfs
	echo "Rebuilding initramfs..."
	update-initramfs -c -k all
	
	# Set ZFSBootMenu command-line arguments for inherited ZFS properties
	echo "Configuring ZFSBootMenu command-line arguments..."
	zfs set org.zfsbootmenu:commandline="quiet" $POOL_NAME/ROOT
	
	# Set up EFI filesystem
	echo "Setting up EFI filesystem..."
	mkfs.vfat -F32 "$BOOT_DEVICE"
	
	# Configure fstab entry for EFI
	echo "Configuring fstab for EFI partition..."
		cat <<-EOF_FSTAB >> /etc/fstab
		$(blkid | grep "$BOOT_DEVICE" | cut -d ' ' -f 2) /boot/efi vfat defaults 0 0
		EOF_FSTAB
	
	# Mount EFI partition
	mkdir -p /boot/efi
	mount /boot/efi
	
	# Install ZFSBootMenu
	echo "Installing ZFSBootMenu..."
	mkdir -p /boot/efi/EFI/ZBM
 	mkdir -p /boot/efi/EFI/BOOT
	curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
	cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
	cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/BOOT/bootx64.efi  # Default path if needed
	
	# Mount EFI variables if needed
	echo "Mounting efivarfs for boot entry setup..."
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars
	
	# Install and configure EFI boot manager
	echo "Configuring EFI boot entries..."
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\BOOT\bootx64.efi'
	
	EOF
}

cleanup_chroot() {
  echo "Cleaning up chroot environment..."
  umount -l $MOUNT_POINT/dev/pts
  umount -l $MOUNT_POINT/dev
  umount -l $MOUNT_POINT/sys
  umount -l $MOUNT_POINT/proc
}

final_cleanup() {
  echo "Exporting ZFS pool and completing installation..."
  mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | \
    xargs -i{} umount -lf {}
  zpool export -a
}

# Execution sequence
setup_debug_logging
echo "Starting ZFS Boot Menu installation..."
refresh_device_vars
log_environment_snapshot
select_disk
get_username_and_password
log_selected_configuration
configure_apt_sources
sync_system_clock
install_host_packages
generate_hostid
partition_disk
create_zpool
export_import_zpool
setup_base_system
prepare_chroot
enter_chroot
cleanup_chroot
final_cleanup

echo "ZFS Boot Menu installation complete. You may reboot."
