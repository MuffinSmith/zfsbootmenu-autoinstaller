#!/bin/bash

set -Eeo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# Automatically set other variables
DEBIAN_RELEASE="trixie"
FEDORA_RELEASE=""
BOOT_DISK="/dev/nvme0n1"
BOOT_PART="1"
POOL_DISK="/dev/nvme0n1"
POOL_PART="2"
POOL_NAME="zroot"
KERNEL_VERSION=$(uname -r)  # Automatically get current kernel version
MOUNT_POINT="/mnt"
LIVE_DISTRO_ID=$(source /etc/os-release && echo "$ID")
LIVE_DISTRO_VERSION=$(source /etc/os-release && echo "$VERSION_ID")
TARGET_DISTRO=""
TARGET_RELEASE=""
ID="$LIVE_DISTRO_ID"
ZPOOL_COMPATIBILITY="openzfs-2.2-linux"
TARGET_ADMIN_GROUP="sudo"
FEDORA_ZFS_RELEASE_URL=""
FEDORA_PKG_MANAGER=""
DEBUG_LOG=""
SHARE_NAME="zfsbootmenu"
SHARE_USER="user"
SHARE_PASSWORD="password"
SMB_SHARE_DIR="/var/lib/zfsbootmenu-share"
SMB_READY="0"
SMB_IPS=""
SNAPSHOT_PACKAGE_ROOT="https://snapshot.debian.org/package/linux"
NETWORK_MODE=""
NETWORK_INTERFACE=""
NETWORK_INTERFACE_MAC=""
NETWORK_IPV4_CIDR=""
NETWORK_GATEWAY=""
NETWORK_DNS_SERVERS=""

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

detect_target_configuration() {
	case "$LIVE_DISTRO_ID" in
		debian)
			TARGET_DISTRO="debian"
			TARGET_RELEASE="$DEBIAN_RELEASE"
			ID="$TARGET_DISTRO"
			ZPOOL_COMPATIBILITY="openzfs-2.2-linux"
			TARGET_ADMIN_GROUP="sudo"
			;;
		fedora)
			if [[ -z "$LIVE_DISTRO_VERSION" ]]; then
				echo "Unable to determine the Fedora release from /etc/os-release"
				return 1
			fi
			FEDORA_RELEASE="$LIVE_DISTRO_VERSION"
			TARGET_DISTRO="fedora"
			TARGET_RELEASE="$FEDORA_RELEASE"
			ID="$TARGET_DISTRO"
			ZPOOL_COMPATIBILITY="openzfs-2.3-linux"
			TARGET_ADMIN_GROUP="wheel"
			;;
		*)
			echo "Unsupported live distribution: $LIVE_DISTRO_ID"
			echo "Supported live environments: Debian live -> Debian target, Fedora Server installer -> Fedora target"
			return 1
			;;
	esac
}

log_environment_snapshot() {
	echo "=== ZFSBootMenu installer debug context ==="
	echo "Start time: $(date -Iseconds 2>/dev/null || date)"
	echo "Live OS ID: $LIVE_DISTRO_ID"
	echo "Live OS release: ${LIVE_DISTRO_VERSION:-unknown}"
	echo "Target OS ID: $TARGET_DISTRO"
	echo "Target OS release: $TARGET_RELEASE"
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
	echo "Target distro: $TARGET_DISTRO"
	echo "Target release: $TARGET_RELEASE"
	echo "Pool name: $POOL_NAME"
	echo "Mount point: $MOUNT_POINT"
	echo "Hostname: $HOSTNAME"
	echo "Username: $USERNAME"
	if [[ -n "$NETWORK_INTERFACE" && -n "$NETWORK_INTERFACE_MAC" ]]; then
		echo "Configured network interface: $NETWORK_INTERFACE"
		echo "Configured network MAC: $NETWORK_INTERFACE_MAC"
		echo "IPv4 network mode: $NETWORK_MODE"
		echo "IPv6 network mode: router assignment"
		if [[ "$NETWORK_MODE" == "static" ]]; then
			echo "Static IPv4 address: $NETWORK_IPV4_CIDR"
			echo "Static IPv4 gateway: $NETWORK_GATEWAY"
			if [[ -n "$NETWORK_DNS_SERVERS" ]]; then
				echo "Static DNS servers: $NETWORK_DNS_SERVERS"
			fi
		fi
	else
		echo "First-boot wired networking: not configured"
	fi
}

get_interface_mac() {
	local interface_name="$1"

	cat "/sys/class/net/${interface_name}/address" 2>/dev/null || true
}

list_candidate_network_interfaces() {
	local interface_path=""
	local interface_name=""

	for interface_path in /sys/class/net/*; do
		interface_name=$(basename "$interface_path")
		if [[ "$interface_name" == "lo" ]]; then
			continue
		fi
		if [[ ! -e "$interface_path/device" ]]; then
			continue
		fi
		if [[ -d "$interface_path/wireless" ]]; then
			continue
		fi
		echo "$interface_name"
	done | sort
}

select_network_interface() {
	local interfaces=()
	local interface_choice=""
	local interface_index=""

	mapfile -t interfaces < <(list_candidate_network_interfaces)

	if [[ ${#interfaces[@]} -eq 0 ]]; then
		echo "No wired network interfaces detected. Automatic first-boot networking will not be configured."
		NETWORK_MODE="none"
		return
	fi

	if [[ ${#interfaces[@]} -eq 1 ]]; then
		NETWORK_INTERFACE="${interfaces[0]}"
		NETWORK_INTERFACE_MAC=$(get_interface_mac "$NETWORK_INTERFACE")
		echo "Detected wired network interface: $NETWORK_INTERFACE ($NETWORK_INTERFACE_MAC)"
		return
	fi

	echo "Available wired network interfaces:"
	for interface_index in "${!interfaces[@]}"; do
		echo "$((interface_index + 1)). ${interfaces[$interface_index]} ($(get_interface_mac "${interfaces[$interface_index]}"))"
	done

	while true; do
		read -p "Enter the number of the interface to configure: " interface_choice
		if [[ "$interface_choice" =~ ^[0-9]+$ ]] && (( interface_choice > 0 && interface_choice <= ${#interfaces[@]} )); then
			NETWORK_INTERFACE="${interfaces[$((interface_choice - 1))]}"
			NETWORK_INTERFACE_MAC=$(get_interface_mac "$NETWORK_INTERFACE")
			echo "Selected network interface: $NETWORK_INTERFACE ($NETWORK_INTERFACE_MAC)"
			break
		fi
		echo "Invalid choice. Please select a number from the list."
	done
}

get_network_configuration() {
	local mode_choice=""

	select_network_interface
	if [[ "$NETWORK_MODE" == "none" || -z "$NETWORK_INTERFACE" || -z "$NETWORK_INTERFACE_MAC" ]]; then
		return
	fi

	while true; do
		read -p "Configure IPv4 with DHCP or static? [dhcp/static]: " mode_choice
		mode_choice=${mode_choice,,}
		if [[ -z "$mode_choice" || "$mode_choice" == "dhcp" ]]; then
			NETWORK_MODE="dhcp"
			NETWORK_IPV4_CIDR=""
			NETWORK_GATEWAY=""
			NETWORK_DNS_SERVERS=""
			break
		fi
		if [[ "$mode_choice" == "static" ]]; then
			NETWORK_MODE="static"
			while true; do
				read -p "Enter static IPv4 address with prefix (e.g. 192.168.1.10/24): " NETWORK_IPV4_CIDR
				if [[ "$NETWORK_IPV4_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
					break
				fi
				echo "Invalid IPv4 address/prefix format."
			done
			while true; do
				read -p "Enter IPv4 gateway: " NETWORK_GATEWAY
				if [[ "$NETWORK_GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
					break
				fi
				echo "Invalid IPv4 gateway format."
			done
			read -p "Enter DNS servers separated by spaces (optional): " NETWORK_DNS_SERVERS
			NETWORK_DNS_SERVERS=${NETWORK_DNS_SERVERS//,/ }
			NETWORK_DNS_SERVERS=$(printf '%s\n' "$NETWORK_DNS_SERVERS" | xargs 2>/dev/null || true)
			break
		fi
		echo "Invalid choice. Enter 'dhcp' or 'static'."
	done

	echo "IPv6 will use router assignment when available."
}

quiesce_apt_background_tasks() {
	if ! command -v systemctl >/dev/null 2>&1; then
		return
	fi

	systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
	systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
	systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
}

wait_for_apt_locks() {
	local lock_file=""
	local waited=0
	local timeout_seconds=120
	local lock_files=(
		/var/lib/dpkg/lock-frontend
		/var/lib/dpkg/lock
		/var/lib/apt/lists/lock
		/var/cache/apt/archives/lock
	)

	if ! command -v fuser >/dev/null 2>&1; then
		return 0
	fi

	while true; do
		lock_file=""
		for candidate in "${lock_files[@]}"; do
			if [[ -e "$candidate" ]] && fuser "$candidate" >/dev/null 2>&1; then
				lock_file="$candidate"
				break
			fi
		done

		if [[ -z "$lock_file" ]]; then
			return 0
		fi

		if (( waited == 0 )); then
			echo "Waiting for package manager locks to clear..."
		fi

		if (( waited >= timeout_seconds )); then
			echo "Timed out waiting for package manager lock: $lock_file"
			return 1
		fi

		sleep 2
		waited=$((waited + 2))
	done
}

apt_get_safe() {
	wait_for_apt_locks
	apt-get "$@"
}

resolve_fedora_package_manager() {
	local candidate=""

	if [[ -n "$FEDORA_PKG_MANAGER" ]] && command -v "$FEDORA_PKG_MANAGER" >/dev/null 2>&1; then
		printf '%s\n' "$FEDORA_PKG_MANAGER"
		return 0
	fi

	for candidate in dnf dnf5 microdnf; do
		if command -v "$candidate" >/dev/null 2>&1; then
			FEDORA_PKG_MANAGER="$candidate"
			printf '%s\n' "$FEDORA_PKG_MANAGER"
			return 0
		fi
	done

	echo "Unable to find a Fedora package manager (dnf, dnf5, or microdnf)" >&2
	return 1
}

install_log_sharing_packages() {
	local distro="${TARGET_DISTRO:-$LIVE_DISTRO_ID}"
	local fedora_pkg_manager=""

	case "$distro" in
		debian)
			quiesce_apt_background_tasks
			apt_get_safe update
			apt_get_safe install -y samba
			;;
		fedora)
			fedora_pkg_manager=$(resolve_fedora_package_manager)
			"$fedora_pkg_manager" install -y samba
			;;
		*)
			echo "Unable to install Samba automatically for unsupported distro: $distro"
			return 1
			;;
	esac
}

dnf_install_live() {
	local fedora_pkg_manager=""
	fedora_pkg_manager=$(resolve_fedora_package_manager)
	echo "Running Fedora live package command: $fedora_pkg_manager -y --releasever=$FEDORA_RELEASE --setopt=install_weak_deps=False $*"
	"$fedora_pkg_manager" -y --releasever="$FEDORA_RELEASE" --setopt=install_weak_deps=False "$@"
}

dnf_install_live_release_only() {
	local fedora_pkg_manager=""
	fedora_pkg_manager=$(resolve_fedora_package_manager)
	echo "Running Fedora live release-only command: $fedora_pkg_manager -y --releasever=$FEDORA_RELEASE --setopt=install_weak_deps=False --disablerepo=updates $*"
	"$fedora_pkg_manager" -y --releasever="$FEDORA_RELEASE" --setopt=install_weak_deps=False --disablerepo=updates "$@"
}

dnf_install_target() {
	local fedora_pkg_manager=""
	fedora_pkg_manager=$(resolve_fedora_package_manager)
	echo "Running Fedora installroot command: $fedora_pkg_manager -y --installroot $MOUNT_POINT --use-host-config --releasever=$FEDORA_RELEASE --setopt=install_weak_deps=False $*"
	"$fedora_pkg_manager" -y --installroot "$MOUNT_POINT" --use-host-config --releasever="$FEDORA_RELEASE" --setopt=install_weak_deps=False "$@"
}

dnf_install_target_release_only() {
	local fedora_pkg_manager=""
	fedora_pkg_manager=$(resolve_fedora_package_manager)
	echo "Running Fedora installroot release-only command: $fedora_pkg_manager -y --installroot $MOUNT_POINT --use-host-config --releasever=$FEDORA_RELEASE --setopt=install_weak_deps=False --disablerepo=updates $*"
	"$fedora_pkg_manager" -y --installroot "$MOUNT_POINT" --use-host-config --releasever="$FEDORA_RELEASE" --setopt=install_weak_deps=False --disablerepo=updates "$@"
}

url_exists() {
	local url="$1"

	if command -v curl >/dev/null 2>&1; then
		curl -fsIL "$url" >/dev/null 2>&1
	elif command -v wget >/dev/null 2>&1; then
		wget -q --spider "$url"
	else
		return 1
	fi
}

fedora_zfs_release_candidates() {
	printf '%s\n' \
		"https://zfsonlinux.org/fedora/zfs-release-3-1.fc${FEDORA_RELEASE}.noarch.rpm" \
		"https://zfsonlinux.org/fedora/zfs-release-3-0.fc${FEDORA_RELEASE}.noarch.rpm" \
		"https://zfsonlinux.org/fedora/zfs-release-2-8.fc${FEDORA_RELEASE}.noarch.rpm" \
		"https://zfsonlinux.org/fedora/zfs-release-2-6.fc${FEDORA_RELEASE}.noarch.rpm" \
		"https://zfsonlinux.org/fedora/zfs-release-2-5.fc${FEDORA_RELEASE}.noarch.rpm"
}

resolve_fedora_zfs_release_rpm() {
	local candidate=""

	if [[ -n "$FEDORA_ZFS_RELEASE_URL" ]]; then
		printf '%s\n' "$FEDORA_ZFS_RELEASE_URL"
		return 0
	fi

	echo "Resolving Fedora zfs-release RPM for Fedora $FEDORA_RELEASE" >&2
	while IFS= read -r candidate; do
		echo "Checking Fedora zfs-release candidate: $candidate" >&2
		if [[ -n "$candidate" ]] && url_exists "$candidate"; then
			FEDORA_ZFS_RELEASE_URL="$candidate"
			echo "Using Fedora zfs-release RPM: $FEDORA_ZFS_RELEASE_URL" >&2
			printf '%s\n' "$FEDORA_ZFS_RELEASE_URL"
			return 0
		fi
	done < <(fedora_zfs_release_candidates)

	echo "Unable to find a compatible zfs-release RPM for Fedora $FEDORA_RELEASE" >&2
	return 1
}

fedora_kernel_devel_url() {
	printf '%s\n' "https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_RELEASE}/Everything/x86_64/os/Packages/k/kernel-devel-${KERNEL_VERSION}.rpm"
}

remove_zfs_fuse_if_present() {
	if command -v rpm >/dev/null 2>&1 && rpm -q zfs-fuse >/dev/null 2>&1; then
		rpm -e --nodeps zfs-fuse
	fi
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
   follow symlinks = yes
   wide links = yes
   unix extensions = no
   valid users = ${SHARE_USER}
EOF
}

configure_samba_share_access() {
	if command -v getenforce >/dev/null 2>&1; then
		if [[ "$(getenforce 2>/dev/null || true)" != "Disabled" ]]; then
			chcon -R -t samba_share_t "$SMB_SHARE_DIR" 2>/dev/null || true
		fi
	fi

	if command -v firewall-cmd >/dev/null 2>&1; then
		if firewall-cmd --state >/dev/null 2>&1; then
			firewall-cmd --quiet --add-service=samba >/dev/null 2>&1 || true
		fi
	fi
}

start_samba_service() {
	pkill smbd 2>/dev/null || true

	if command -v systemctl >/dev/null 2>&1; then
		systemctl restart smbd 2>/dev/null || systemctl start smbd 2>/dev/null || true
		systemctl restart smb 2>/dev/null || systemctl start smb 2>/dev/null || true
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
	cp -f "$DEBUG_LOG" "$SMB_SHARE_DIR/latest.log"
	chmod 0755 "$SMB_SHARE_DIR"
	chmod 0644 "$SMB_SHARE_DIR"/* 2>/dev/null || true

	if ! command -v smbd >/dev/null 2>&1 || ! command -v smbpasswd >/dev/null 2>&1; then
		echo "Installing Samba packages for log sharing..."
		set +e
		install_log_sharing_packages
		install_rc=$?
		set -e
		if [[ $install_rc -ne 0 ]]; then
			echo "Unable to install Samba packages automatically."
			return
		fi
	fi

	ensure_share_user || return
	write_samba_config
	configure_samba_share_access
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
	local package_url_pattern='(https://snapshot\.debian\.org)?/archive/debian/[^"]*'

	package_url=$(printf '%s\n' "$snapshot_page" | grep -oE "${package_url_pattern}/${package_pattern}" | head -n1 || true)

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
	apt_get_safe install -y "$temp_dir"/*.deb
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
		apt_get_safe install -y "$header_package"
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

configure_package_sources() {
	case "$TARGET_DISTRO" in
		debian)
			configure_apt_sources
			;;
		fedora)
			echo "Using Fedora package repositories from the live environment."
			;;
		*)
			echo "Unsupported target distro for package source configuration: $TARGET_DISTRO"
			return 1
			;;
	esac
}

install_host_packages_debian() {
	echo "Installing necessary packages"
	quiesce_apt_background_tasks
	apt_get_safe update
	apt_get_safe install -y debootstrap gdisk dkms curl
	install_live_kernel_headers
	apt_get_safe install -y dosfstools efibootmgr zfsutils-linux
	echo "Loading ZFS module for the live environment"
	modprobe zfs
	prepare_host_efi_support
}

install_host_packages_fedora() {
	local zfs_release_url=""

	echo "Installing necessary packages"
	zfs_release_url=$(resolve_fedora_zfs_release_rpm)
	echo "Resolved Fedora live zfs-release RPM: $zfs_release_url"
	dnf_install_live install gdisk curl wget dosfstools efibootmgr
	remove_zfs_fuse_if_present
	if ! rpm -q zfs-release >/dev/null 2>&1; then
		dnf_install_live_release_only install "$zfs_release_url"
	fi
	dnf_install_live_release_only install "$(fedora_kernel_devel_url)"
	dnf_install_live_release_only install zfs
	echo "Loading ZFS module for the live environment"
	modprobe zfs
	prepare_host_efi_support
}

install_host_packages() {
	case "$TARGET_DISTRO" in
		debian)
			install_host_packages_debian
			;;
		fedora)
			install_host_packages_fedora
			;;
		*)
			echo "Unsupported target distro for host package installation: $TARGET_DISTRO"
			return 1
			;;
	esac
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
	local root_dataset="$POOL_NAME/ROOT/$ID"
	local be_local_datasets=("etc" "opt" "usr" "var" "var/cache" "var/lib" "var/log")
	local shared_datasets=("home" "media" "srv")
	local dataset_path=""

  echo "Creating ZFS pool and datasets..."
	zpool create -f -o ashift=12 -O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on -o autotrim=on -o compatibility="$ZPOOL_COMPATIBILITY" -m none "$POOL_NAME" "$POOL_DEVICE"
	zfs create -u -o mountpoint=none "$POOL_NAME/ROOT"
	zfs create -u -o mountpoint=/ -o canmount=noauto "$root_dataset"
	for dataset_path in "${be_local_datasets[@]}"; do
		zfs create -u -o mountpoint="/$dataset_path" "$root_dataset/$dataset_path"
	done
	for dataset_path in "${shared_datasets[@]}"; do
		zfs create -u -o mountpoint="/$dataset_path" "$POOL_NAME/$dataset_path"
	done
	zpool set bootfs="$root_dataset" "$POOL_NAME"
}

export_import_zpool() {
	local root_dataset="$POOL_NAME/ROOT/$ID"
	local be_local_datasets=("etc" "opt" "usr" "var" "var/cache" "var/lib" "var/log")
	local shared_datasets=("home" "media" "srv")
	local dataset_path=""

  echo "Exporting and re-importing ZFS pool for mounting..."
	zpool export "$POOL_NAME"
	udevadm settle 2>/dev/null || true
	zpool import -N -R "$MOUNT_POINT" -d "$POOL_DEVICE" "$POOL_NAME"
	zfs mount "$root_dataset"
	for dataset_path in "${be_local_datasets[@]}"; do
		zfs mount "$root_dataset/$dataset_path"
	done
	for dataset_path in "${shared_datasets[@]}"; do
		zfs mount "$POOL_NAME/$dataset_path"
	done
	udevadm trigger
}

setup_base_system_debian() {
	echo "Installing base system with debootstrap..."
	debootstrap "$DEBIAN_RELEASE" "$MOUNT_POINT"
	cp /etc/hostid "$MOUNT_POINT/etc/hostid"
	cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"
}

setup_base_system_fedora() {
	local target_base_packages=(
		@core
		kernel
		kernel-devel
		sudo
		openssh-server
		curl
		dosfstools
		efibootmgr
		policycoreutils
		selinux-policy-targeted
	)

	echo "Installing Fedora target packages into $MOUNT_POINT with dnf --installroot..."
	mkdir -p "$MOUNT_POINT"
	prepare_runtime_mounts
	dnf_install_target_release_only install --exclude=dracut-config-rescue "${target_base_packages[@]}"
	mkdir -p "$MOUNT_POINT/etc"
	if [[ -e "$MOUNT_POINT/etc/resolv.conf" ]]; then
		if [[ "$MOUNT_POINT/etc/resolv.conf" -ef /etc/resolv.conf ]]; then
			echo "Fedora target resolv.conf already shares the live resolver; saving a standalone copy instead."
			cp -L /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf.orig"
		else
			mv "$MOUNT_POINT/etc/resolv.conf" "$MOUNT_POINT/etc/resolv.conf.orig"
			cp -L /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"
		fi
	else
		cp -L /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"
	fi
	cp /etc/hostid "$MOUNT_POINT/etc/hostid"
}

setup_base_system() {
	case "$TARGET_DISTRO" in
		debian)
			setup_base_system_debian
			;;
		fedora)
			setup_base_system_fedora
			;;
		*)
			echo "Unsupported target distro for base system installation: $TARGET_DISTRO"
			return 1
			;;
	esac
}

prepare_runtime_mounts() {
	mkdir -p "$MOUNT_POINT/proc" "$MOUNT_POINT/sys" "$MOUNT_POINT/dev/pts" "$MOUNT_POINT/run"
	mountpoint -q "$MOUNT_POINT/proc" || mount -t proc proc "$MOUNT_POINT/proc"
	mountpoint -q "$MOUNT_POINT/sys" || mount -t sysfs sysfs "$MOUNT_POINT/sys"
	mountpoint -q "$MOUNT_POINT/dev" || mount -B /dev "$MOUNT_POINT/dev"
	mountpoint -q "$MOUNT_POINT/dev/pts" || mount -t devpts devpts "$MOUNT_POINT/dev/pts"
	mountpoint -q "$MOUNT_POINT/run" || mount -B /run "$MOUNT_POINT/run"
}

prepare_chroot() {
  echo "Mounting filesystems for chroot environment..."
  prepare_runtime_mounts
}

enter_chroot_debian() {
	local networkd_config=""
	local networkd_mode_line=""
	local dns_server=""
	local install_network_configuration="0"

	if [[ ( "$NETWORK_MODE" == "dhcp" || "$NETWORK_MODE" == "static" ) && -n "$NETWORK_INTERFACE_MAC" ]]; then
		install_network_configuration="1"
		networkd_config=$'# Generated by setup-zfsbootmenu.sh\n[Match]\n'
		networkd_config+="MACAddress=$NETWORK_INTERFACE_MAC"$'\n\n[Network]\n'
		if [[ "$NETWORK_MODE" == "dhcp" ]]; then
			networkd_mode_line="DHCP=ipv4"
			networkd_config+="$networkd_mode_line"$'\n'
		else
			networkd_config+="Address=$NETWORK_IPV4_CIDR"$'\n'
			networkd_config+="Gateway=$NETWORK_GATEWAY"$'\n'
			for dns_server in $NETWORK_DNS_SERVERS; do
				networkd_config+="DNS=$dns_server"$'\n'
			done
		fi
		networkd_config+="IPv6AcceptRA=yes"$'\n'
	fi

	echo "Entering chroot environment to configure Debian system..."
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
	apt install -y systemd-timesyncd systemd-resolved net-tools iproute2 isc-dhcp-client iputils-ping traceroute curl wget dnsutils ethtool ifupdown tcpdump nmap nano vim htop openssh-server git tmux
	
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

	# Configure first-boot networking
	if [[ "$install_network_configuration" == "1" ]]; then
		echo "Configuring first-boot networking..."
		cat > /etc/network/interfaces <<-'EOF_INTERFACES'
		auto lo
		iface lo inet loopback
		EOF_INTERFACES
		mkdir -p /etc/systemd/network
		cat > /etc/systemd/network/20-installer-primary.network <<-'EOF_NETWORKD'
$networkd_config
		EOF_NETWORKD
		systemctl enable systemd-networkd >/dev/null 2>&1 || systemctl enable systemd-networkd
		if [[ -f /usr/lib/systemd/system/systemd-resolved.service || -f /lib/systemd/system/systemd-resolved.service ]]; then
			systemctl enable systemd-resolved >/dev/null 2>&1 || systemctl enable systemd-resolved
		else
			echo "systemd-resolved service is unavailable; leaving /etc/resolv.conf unchanged."
		fi
		systemctl disable systemd-networkd-wait-online.service systemd-networkd-wait-online@.service >/dev/null 2>&1 || true
	else
		echo "Skipping automatic first-boot wired network configuration."
	fi
	
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
	boot_uuid=\$(blkid -s UUID -o value "$BOOT_DEVICE")
	if [[ -z "\$boot_uuid" ]]; then
		echo "Unable to determine the EFI partition UUID for $BOOT_DEVICE"
		exit 1
	fi
	
	# Configure fstab entry for EFI
	echo "Configuring fstab for EFI partition..."
		printf 'UUID=%s /boot/efi vfat defaults 0 0\n' "\$boot_uuid" >> /etc/fstab
	
	# Mount EFI partition
	mkdir -p /boot/efi
	mount "$BOOT_DEVICE" /boot/efi
	
	# Install ZFSBootMenu
	echo "Installing ZFSBootMenu..."
	mkdir -p /boot/efi/EFI/ZBM
 	mkdir -p /boot/efi/EFI/BOOT
	curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
	cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
	cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/BOOT/bootx64.efi
	
	# Mount EFI variables if needed
	echo "Mounting efivarfs for boot entry setup..."
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars
	
	# Install and configure EFI boot manager
	echo "Configuring EFI boot entries..."
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\BOOT\bootx64.efi'

	# Hand off DNS management to the installed system after all network-dependent setup is done.
	if [[ "$install_network_configuration" == "1" ]]; then
		if [[ -f /usr/lib/systemd/system/systemd-resolved.service || -f /lib/systemd/system/systemd-resolved.service ]]; then
			rm -f /etc/resolv.conf
			ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
		fi
	fi
	
	EOF
}

enter_chroot_fedora() {
	local networkd_config=""
	local networkd_mode_line=""
	local dns_server=""
	local install_network_configuration="0"
	local zfs_release_url=""
	local root_password_hash=""
	local user_password_hash=""

	if [[ ( "$NETWORK_MODE" == "dhcp" || "$NETWORK_MODE" == "static" ) && -n "$NETWORK_INTERFACE_MAC" ]]; then
		install_network_configuration="1"
		networkd_config=$'# Generated by setup-zfsbootmenu.sh\n[Match]\n'
		networkd_config+="MACAddress=$NETWORK_INTERFACE_MAC"$'\n\n[Network]\n'
		if [[ "$NETWORK_MODE" == "dhcp" ]]; then
			networkd_mode_line="DHCP=ipv4"
			networkd_config+="$networkd_mode_line"$'\n'
		else
			networkd_config+="Address=$NETWORK_IPV4_CIDR"$'\n'
			networkd_config+="Gateway=$NETWORK_GATEWAY"$'\n'
			for dns_server in $NETWORK_DNS_SERVERS; do
				networkd_config+="DNS=$dns_server"$'\n'
			done
		fi
		networkd_config+="IPv6AcceptRA=yes"$'\n'
	fi

	zfs_release_url=$(resolve_fedora_zfs_release_rpm)
	if ! command -v openssl >/dev/null 2>&1; then
		echo "openssl is required to configure Fedora target passwords"
		return 1
	fi
	root_password_hash=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin)
	user_password_hash=$(printf '%s' "$USER_PASSWORD" | openssl passwd -6 -stdin)
	echo "Resolved Fedora target zfs-release RPM for chroot: $zfs_release_url"

	echo "Entering chroot environment to configure Fedora system..."
	chroot $MOUNT_POINT /bin/bash <<-EOF
	set -Eeo pipefail

	chroot_log_error() {
		local line_no="\$1"
		local exit_code="\$2"
		echo "[chroot] ERROR: command failed at line \${line_no} with exit code \${exit_code}"
	}

	trap 'chroot_log_error \$LINENO \$?' ERR

	resolve_chroot_fedora_package_manager() {
		local candidate=""
		for candidate in dnf dnf5 microdnf; do
			if command -v "\$candidate" >/dev/null 2>&1; then
				printf '%s\n' "\$candidate"
				return 0
			fi
		done
		echo "[chroot] Unable to find a Fedora package manager (dnf, dnf5, or microdnf)"
		return 1
	}

	fedora_chroot_install() {
		"\$FEDORA_CHROOT_PKG_MANAGER" -y --releasever="$FEDORA_RELEASE" --setopt=install_weak_deps=False --disablerepo=updates install "\$@"
	}

	FEDORA_CHROOT_PKG_MANAGER=\$(resolve_chroot_fedora_package_manager)
	echo "Using Fedora chroot package manager: \$FEDORA_CHROOT_PKG_MANAGER"

	clear_account_locks() {
		local lock_file=""
		for lock_file in /etc/.pwd.lock /etc/passwd.lock /etc/group.lock /etc/gshadow.lock /etc/shadow.lock; do
			if [[ -e "\$lock_file" ]]; then
				echo "Removing stale account lock: \$lock_file"
				rm -f "\$lock_file"
			fi
		done
	}

	# Set hostname
	echo "$HOSTNAME" > /etc/hostname
	echo "127.0.1.1    $HOSTNAME" >> /etc/hosts

	# Install the Fedora target packages that are intentionally kept outside the initial installroot bootstrap.
	echo "Installing Fedora ZFS packages inside chroot..."
	if rpm -q zfs-fuse >/dev/null 2>&1; then
		rpm -e --nodeps zfs-fuse
	fi
	if ! rpm -q zfs-release >/dev/null 2>&1; then
		fedora_chroot_install "$zfs_release_url"
	fi
	if ! rpm -q kernel-devel >/dev/null 2>&1; then
		fedora_chroot_install kernel-devel
	fi
	if ! rpm -q openssh-server >/dev/null 2>&1; then
		fedora_chroot_install openssh-server
	fi
	if ! rpm -q sudo >/dev/null 2>&1; then
		fedora_chroot_install sudo
	fi
	fedora_chroot_install zfs zfs-dracut

	# Configure locale
	echo "Configuring locale..."
	echo 'LANG=en_US.UTF-8' > /etc/locale.conf

	# Set root password
	clear_account_locks
	echo "Setting root password..."
	usermod --password '$root_password_hash' root

	# Create user and set password
	clear_account_locks
	echo "Creating user and setting permissions..."
	fedora_groups="$TARGET_ADMIN_GROUP"
	for candidate_group in audio cdrom dialout netdev plugdev video; do
		if getent group "\$candidate_group" >/dev/null 2>&1; then
			fedora_groups+=",\$candidate_group"
		fi
	done
	useradd -m -s /bin/bash -G "\$fedora_groups" -p '$user_password_hash' $USERNAME

	# Configure first-boot networking
	if [[ "$install_network_configuration" == "1" ]]; then
		echo "Configuring first-boot networking..."
		mkdir -p /etc/systemd/network
		cat > /etc/systemd/network/20-installer-primary.network <<-'EOF_NETWORKD'
$networkd_config
		EOF_NETWORKD
		if [[ -f /usr/lib/systemd/system/NetworkManager.service || -f /lib/systemd/system/NetworkManager.service ]]; then
			systemctl disable NetworkManager.service NetworkManager-wait-online.service >/dev/null 2>&1 || true
		fi
		systemctl enable systemd-networkd >/dev/null 2>&1 || systemctl enable systemd-networkd
		if [[ -f /usr/lib/systemd/system/systemd-resolved.service || -f /lib/systemd/system/systemd-resolved.service ]]; then
			systemctl enable systemd-resolved >/dev/null 2>&1 || systemctl enable systemd-resolved
		else
			echo "systemd-resolved service is unavailable; leaving /etc/resolv.conf unchanged."
		fi
		systemctl disable systemd-networkd-wait-online.service systemd-networkd-wait-online@.service >/dev/null 2>&1 || true
	else
		echo "Skipping automatic first-boot wired network configuration."
	fi

	# Enable core headless services
	echo "Enabling core services..."
	if [[ -f /usr/lib/systemd/system/sshd.service || -f /lib/systemd/system/sshd.service ]]; then
		systemctl enable sshd >/dev/null 2>&1 || systemctl enable sshd
	fi
	if [[ -f /usr/lib/systemd/system/systemd-timesyncd.service || -f /lib/systemd/system/systemd-timesyncd.service ]]; then
		systemctl enable systemd-timesyncd >/dev/null 2>&1 || systemctl enable systemd-timesyncd
	fi
	echo "Configuring headless boot defaults..."
	if [[ -f /usr/lib/systemd/system/display-manager.service || -f /lib/systemd/system/display-manager.service ]]; then
		systemctl disable display-manager.service >/dev/null 2>&1 || true
	fi
	if [[ -f /usr/lib/systemd/system/gdm.service || -f /lib/systemd/system/gdm.service ]]; then
		systemctl disable gdm >/dev/null 2>&1 || true
	fi
	systemctl set-default multi-user.target >/dev/null 2>&1 || systemctl set-default multi-user.target

	# Configure Dracut for ZFS root imports
	echo "Configuring Dracut for ZFS..."
	mkdir -p /etc/dracut.conf.d
	cat > /etc/dracut.conf.d/zol.conf <<-'EOF_DRACUT'
	nofsck="yes"
	add_dracutmodules+=" zfs "
	omit_dracutmodules+=" btrfs "
	EOF_DRACUT

	# Enable systemd ZFS services
	echo "Enabling systemd ZFS services..."
	systemctl enable zfs.target
	systemctl enable zfs-import-cache
	systemctl enable zfs-mount
	systemctl enable zfs-import.target

	# Rebuild initramfs
	echo "Rebuilding initramfs..."
	dracut --force --regenerate-all

	# Set ZFSBootMenu command-line arguments for inherited ZFS properties
	echo "Configuring ZFSBootMenu command-line arguments..."
	zfs set org.zfsbootmenu:commandline="quiet" $POOL_NAME/ROOT

	# Set up EFI filesystem
	echo "Setting up EFI filesystem..."
	mkfs.vfat -F32 "$BOOT_DEVICE"
	boot_uuid=\$(blkid -s UUID -o value "$BOOT_DEVICE")
	if [[ -z "\$boot_uuid" ]]; then
		echo "Unable to determine the EFI partition UUID for $BOOT_DEVICE"
		exit 1
	fi

	# Configure fstab entry for EFI
	echo "Configuring fstab for EFI partition..."
	printf 'UUID=%s /boot/efi vfat defaults 0 0\n' "\$boot_uuid" >> /etc/fstab

	# Mount EFI partition
	mkdir -p /boot/efi
	mount "$BOOT_DEVICE" /boot/efi

	# Install ZFSBootMenu
	echo "Installing ZFSBootMenu..."
	mkdir -p /boot/efi/EFI/ZBM
	mkdir -p /boot/efi/EFI/BOOT
	curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
	cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
	cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/BOOT/bootx64.efi

	# Mount EFI variables if needed
	echo "Mounting efivarfs for boot entry setup..."
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars

	# Install and configure EFI boot manager
	echo "Configuring EFI boot entries..."
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\BOOT\bootx64.efi'

	# Hand off DNS management to the installed system after all network-dependent setup is done.
	if [[ "$install_network_configuration" == "1" ]]; then
		if [[ -f /usr/lib/systemd/system/systemd-resolved.service || -f /lib/systemd/system/systemd-resolved.service ]]; then
			rm -f /etc/resolv.conf
			ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
			rm -f /etc/resolv.conf.orig
		elif [[ -f /etc/resolv.conf.orig ]]; then
			mv -f /etc/resolv.conf.orig /etc/resolv.conf
		fi
	elif [[ -f /etc/resolv.conf.orig ]]; then
		mv -f /etc/resolv.conf.orig /etc/resolv.conf
	fi

	# Ensure custom files written in the chroot get correct SELinux labels on first boot.
	echo "Scheduling SELinux relabel on first boot..."
	touch /.autorelabel
	EOF
}

enter_chroot() {
	case "$TARGET_DISTRO" in
		debian)
			enter_chroot_debian
			;;
		fedora)
			enter_chroot_fedora
			;;
		*)
			echo "Unsupported target distro for chroot configuration: $TARGET_DISTRO"
			return 1
			;;
	esac
}

cleanup_chroot() {
  echo "Cleaning up chroot environment..."
	umount -l "$MOUNT_POINT/run" 2>/dev/null || true
	umount -l "$MOUNT_POINT/dev/pts" 2>/dev/null || true
	umount -l "$MOUNT_POINT/dev" 2>/dev/null || true
	umount -l "$MOUNT_POINT/sys" 2>/dev/null || true
	umount -l "$MOUNT_POINT/proc" 2>/dev/null || true
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
detect_target_configuration
refresh_device_vars
log_environment_snapshot
select_disk
get_username_and_password
get_network_configuration
log_selected_configuration
configure_package_sources
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
