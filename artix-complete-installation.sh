#!/bin/bash

# Artix Linux Complete Installation Script
# This script performs full disk encryption setup and system installation
# Use at your own risk and make sure you understand what it does before running

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
DISK=""
BOOT_SIZE=""
SWAP_SIZE=""
SWAP_UUID=""

# Output functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}===== $1 =====${NC}"
}

# Utility functions
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

show_available_disks() {
    echo "Available disks:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
    echo ""
}

get_user_input() {
    local prompt="$1"
    local var_name="$2"
    local validation_func="$3"

    while true; do
        read -p "$prompt: " input
        if [[ -n "$input" ]] && ([[ -z "$validation_func" ]] || $validation_func "$input"); then
            eval "$var_name='$input'"
            break
        else
            print_error "Invalid input. Please try again."
        fi
    done
}

# Validation functions
validate_timezone() {
    [[ -f "/usr/share/zoneinfo/$1" ]]
}

validate_disk() {
    [[ -b "/dev/$1" ]]
}

#=============================================================================
# PHASE 1: DISK ENCRYPTION SETUP
#=============================================================================

get_disk_configuration() {
    print_header "DISK CONFIGURATION"

    # Show available disks first
    show_available_disks

    # Get disk selection
    while true; do
        read -p "Enter the disk to use (e.g., sda, vda, nvme0n1): " disk_input

        # Add /dev/ prefix if not present
        if [[ "$disk_input" == /dev/* ]]; then
            DISK="$disk_input"
        else
            DISK="/dev/$disk_input"
        fi

        # Check if disk exists
        if [[ -b "$DISK" ]]; then
            break
        else
            print_error "Disk $DISK does not exist. Please try again."
            show_available_disks
        fi
    done

    # Get partition sizes
    echo ""
    echo "Enter partition sizes (you can use units like G for gigabytes, M for megabytes):"
    echo "Examples: 1G, 512M, 16G"
    echo ""

    read -p "Boot partition size (recommended: 1G): " BOOT_SIZE
    read -p "Swap partition size (recommended: equal to or 2x your RAM): " SWAP_SIZE

    # Validate sizes have units
    if [[ ! "$BOOT_SIZE" =~ [0-9]+[GMK]$ ]]; then
        print_warning "Boot size should include units (G/M/K). Assuming gigabytes."
        BOOT_SIZE="${BOOT_SIZE}G"
    fi

    if [[ ! "$SWAP_SIZE" =~ [0-9]+[GMK]$ ]]; then
        print_warning "Swap size should include units (G/M/K). Assuming gigabytes."
        SWAP_SIZE="${SWAP_SIZE}G"
    fi
}

confirm_configuration() {
    print_header "CONFIGURATION SUMMARY"
    echo "Disk: $DISK"
    echo "Boot partition size: $BOOT_SIZE"
    echo "Swap partition size: $SWAP_SIZE"
    echo "Root partition: Uses remaining space"
    echo "Root filesystem: BTRFS"
    echo ""

    lsblk "$DISK"
    echo ""
    print_warning "This will COMPLETELY ERASE disk $DISK"
    print_warning "ALL DATA ON THIS DISK WILL BE LOST!"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "Operation canceled."
        exit 0
    fi
}

ask_secure_erase() {
    print_header "SECURE DISK ERASE OPTION"
    echo "A secure erase will overwrite the entire disk with encrypted random data."
    echo "This is recommended for security but takes significant time."
    echo ""
    echo "Options:"
    echo "1. Perform secure erase (RECOMMENDED for security)"
    echo "2. Skip secure erase (faster, but less secure)"
    echo ""
    read -p "Do you want to perform a secure erase? (Y/n): " erase_choice

    if [[ "$erase_choice" == "n" || "$erase_choice" == "N" ]]; then
        print_info "Skipping secure erase. Only clearing partition table..."
        return 1  # Return false to skip secure erase
    else
        print_info "Proceeding with secure erase..."
        return 0  # Return true to perform secure erase
    fi
}

quick_erase() {
    print_info "Performing quick erase (clearing partition table and filesystem signatures)..."

    # Clear partition table and first few MB
    dd bs=1M if=/dev/zero of="$DISK" count=10 status=progress || true
    sync

    # Clear the end of the disk (backup partition tables)
    local DISK_SIZE
    DISK_SIZE=$(blockdev --getsize64 "$DISK")
    local END_OFFSET=$(( DISK_SIZE - 10*1024*1024 ))  # Last 10MB

    dd bs=1M if=/dev/zero of="$DISK" seek=$((END_OFFSET/1024/1024)) count=10 status=progress || true
    sync

    print_success "Quick erase completed."
}

downgrade_parted() {
    print_info "Downgrading parted to avoid 'unknown filesystem' error..."
    pacman -U "https://archive.artixlinux.org/packages/p/parted/parted-3.4-2-x86_64.pkg.tar.zst" --noconfirm || {
        print_warning "Could not downgrade parted. Continuing anyway..."
    }
}

erase_disk() {
    print_info "Erasing disk $DISK (this may take a while)..."

    # Get disk size to ensure we don't try to write more than its capacity
    local DISK_SIZE
    DISK_SIZE=$(blockdev --getsize64 "$DISK")
    local BLOCK_SIZE=4096

    # First pass with zeros (limited to first 100MB for speed)
    print_info "First pass: Writing zeros to first 100MB of disk..."
    dd bs=$BLOCK_SIZE if=/dev/zero of="$DISK" oflag=direct status=progress count=$((100*1024*1024/BLOCK_SIZE)) || true
    sync

    # Second pass with encrypted zeros (faster than /dev/urandom but cryptographically secure)
    print_info "Second pass: Writing encrypted data to disk for secure erasure..."
    local PASS
    PASS=$(tr -cd '[:alnum:]' < /dev/urandom | head -c128)
    print_info "Using OpenSSL AES-256-CTR for efficient secure erase..."

    # Use a pipe to prevent errors from stopping the process
    set +e  # Temporarily disable exit on error
    openssl enc -aes-256-ctr -pass pass:"$PASS" -nosalt </dev/zero |
        dd bs=64K of="$DISK" oflag=direct status=progress 2>&1 |
        grep -v "No space left on device" || true
    set -e  # Re-enable exit on error

    # Ensure sync after write
    sync

    print_success "Disk erasure completed."
}

create_partition() {
    print_info "Creating partition on $DISK..."
    parted -s "$DISK" mklabel msdos
    parted -s -a optimal "$DISK" mkpart "primary" "btrfs" "0%" "100%"
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" set 1 lvm on
    parted -s "$DISK" print

    # Verify alignment
    local alignment_ok
    alignment_ok=$(parted -s "$DISK" align-check optimal 1)
    print_info "Partition alignment: $alignment_ok"

    # Flush partition table to disk
    partprobe "$DISK"
    sync

    # Wait for partition to be recognized
    sleep 2

    print_success "Partition created: ${DISK}1"
}

setup_encryption() {
    print_info "Setting up disk encryption..."

    # Check for serpent cipher support
    if ! grep -q "serp" /proc/crypto; then
        print_warning "Serpent cipher not found in kernel. You may need to load the appropriate module."
        print_info "Available ciphers:"
        grep "name" /proc/crypto | sort | uniq
    fi

    # Show encryption benchmark
    print_info "Running encryption benchmark..."
    cryptsetup benchmark

    # Create LUKS container
    echo ""
    print_info "Creating LUKS container on ${DISK}1..."
    print_warning "You will be prompted to enter a passphrase for disk encryption."
    print_warning "IMPORTANT: Choose a strong passphrase and remember it - you'll need it to boot your system!"
    echo ""

    # Determine partition name (handle nvme vs sda naming)
    local PARTITION
    if [[ "$DISK" =~ nvme[0-9]+n[0-9]+ ]]; then
        PARTITION="${DISK}p1"
    else
        PARTITION="${DISK}1"
    fi

    cryptsetup --verbose --type luks1 --cipher serpent-xts-plain64 --key-size 512 \
               --hash sha512 --iter-time 10000 --use-random --verify-passphrase luksFormat "$PARTITION"

    # Open LUKS container
    print_info "Opening LUKS container..."
    cryptsetup luksOpen "$PARTITION" lvm-system

    print_success "Encryption setup completed. LUKS container is now open as /dev/mapper/lvm-system"
}

setup_lvm() {
    print_info "Setting up LVM..."
    pvcreate /dev/mapper/lvm-system
    vgcreate lvmSystem /dev/mapper/lvm-system

    # Create logical volumes with user-specified sizes
    print_info "Creating logical volumes..."
    lvcreate --contiguous y --size "$BOOT_SIZE" lvmSystem --name volBoot
    lvcreate --contiguous y --size "$SWAP_SIZE" lvmSystem --name volSwap
    lvcreate --contiguous y --extents +100%FREE lvmSystem --name volRoot

    # Show created volumes
    print_info "Created logical volumes:"
    lvs

    print_success "LVM setup completed"
}

format_partitions() {
    print_info "Formatting partitions..."

    # Format boot partition as FAT32
    print_info "Formatting boot partition (FAT32)..."
    mkfs.fat -F32 -n BOOT /dev/lvmSystem/volBoot

    # Create swap partition
    print_info "Creating swap partition..."
    mkswap -L SWAP /dev/lvmSystem/volSwap

    # Get swap UUID and save it for later use
    SWAP_UUID=$(blkid -s UUID -o value /dev/lvmSystem/volSwap)
    print_info "SWAP UUID: $SWAP_UUID"

    # Format root partition as BTRFS
    print_info "Creating BTRFS root filesystem..."
    mkfs.btrfs -f -L ROOT /dev/lvmSystem/volRoot

    print_success "All partitions formatted successfully."
}

mount_partitions() {
    print_info "Mounting partitions..."

    # Activate swap
    swapon /dev/lvmSystem/volSwap

    # Mount root partition
    mount /dev/lvmSystem/volRoot /mnt

    # Create boot directory and mount boot partition
    mkdir -p /mnt/boot
    mount /dev/lvmSystem/volBoot /mnt/boot

    print_success "Partitions mounted successfully:"
    echo "  Root (BTRFS): /mnt"
    echo "  Boot (FAT32): /mnt/boot"
    echo "  Swap: activated"
}

#=============================================================================
# PHASE 2: SYSTEM INSTALLATION
#=============================================================================

install_base_system() {
    print_header "SYSTEM INSTALLATION"

    print_info "Installing base system packages..."
    basestrap /mnt base base-devel linux linux-headers grub efibootmgr \
        networkmanager networkmanager-runit elogind-runit elogind \
        cryptsetup lvm2 mkinitcpio vim glibc || {
        print_error "Failed to install base system"
        exit 1
    }

    # Generate fstab
    print_info "Generating fstab..."
    fstabgen -U /mnt > /mnt/etc/fstab
    print_success "fstab generated"
}

create_chroot_script() {
    print_info "Creating chroot configuration script..."
    cat > /mnt/chroot_config.sh << 'CHROOT_EOF'
#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() { echo -e "${BLUE}===== $1 =====${NC}"; }

get_user_input() {
    local prompt="$1"
    local var_name="$2"
    local validation_func="$3"

    while true; do
        read -p "$prompt: " input
        if [[ -n "$input" ]] && ([[ -z "$validation_func" ]] || $validation_func "$input"); then
            eval "$var_name='$input'"
            break
        else
            print_error "Invalid input. Please try again."
        fi
    done
}

validate_timezone() {
    [[ -f "/usr/share/zoneinfo/$1" ]]
}

validate_disk() {
    [[ -b "/dev/$1" ]]
}

# Get timezone from user
print_header "TIMEZONE CONFIGURATION"
echo "Available regions:"
ls /usr/share/zoneinfo/ | grep -E '^[A-Z]' | head -10
echo "..."
get_user_input "Enter your region (e.g., America, Europe, Asia)" REGION
if [[ ! -d "/usr/share/zoneinfo/$REGION" ]]; then
    print_error "Invalid region"
    exit 1
fi

echo "Available cities in $REGION:"
ls "/usr/share/zoneinfo/$REGION" | head -10
echo "..."
get_user_input "Enter your city" CITY
TIMEZONE="$REGION/$CITY"

if validate_timezone "$TIMEZONE"; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    print_success "Timezone set to $TIMEZONE"
else
    print_error "Invalid timezone"
    exit 1
fi

# Sync hardware clock
print_info "Syncing hardware clock..."
hwclock --systohc
print_success "Hardware clock synced"

# Set up locale
print_header "LOCALE CONFIGURATION"
cat > /etc/locale.conf << 'LOCALE_EOF'
LANG=en_US.UTF-8
export LC_COLLATE="C"
LOCALE_EOF

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
print_success "Locale configured"

# Get hostname
print_header "HOSTNAME CONFIGURATION"
get_user_input "Enter hostname for this system" HOSTNAME

echo "$HOSTNAME" > /etc/hostname

# Set up hosts file
cat > /etc/hosts << HOSTS_EOF
127.0.0.1    localhost
::1          localhost
127.0.1.1    $HOSTNAME.localdomain $HOSTNAME
HOSTS_EOF
print_success "Hostname set to $HOSTNAME"

# Get disk for bootloader
get_user_input "Enter the disk device name for bootloader (e.g., sda, nvme0n1)" DISK_NAME validate_disk

# Configure mkinitcpio
print_header "INITRAMFS CONFIGURATION"
# Backup original
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.backup

# Replace the HOOKS line
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt keyboard keymap consolefont lvm2 filesystems fsck)/' /etc/mkinitcpio.conf

# Generate initramfs
mkinitcpio -P
print_success "mkinitcpio configured and initramfs generated"

# Configure GRUB
print_header "BOOTLOADER CONFIGURATION"

# Get UUIDs - handle nvme vs sda naming
local PARTITION_NAME
if [[ "$DISK_NAME" =~ nvme[0-9]+n[0-9]+ ]]; then
    PARTITION_NAME="/dev/${DISK_NAME}p1"
else
    PARTITION_NAME="/dev/${DISK_NAME}1"
fi

CRYPT_UUID=$(blkid -s UUID -o value "$PARTITION_NAME")
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/lvmSystem-volRoot)
SWAP_UUID=$(blkid -s UUID -o value /dev/mapper/lvmSystem-volSwap)

if [[ -z "$CRYPT_UUID" || -z "$ROOT_UUID" ]]; then
    print_error "Could not determine UUIDs. Please check your setup."
    exit 1
fi

print_info "Found UUIDs:"
echo "  Encrypted partition: $CRYPT_UUID"
echo "  Root partition: $ROOT_UUID"
echo "  Swap partition: $SWAP_UUID"

# Backup original GRUB config
cp /etc/default/grub /etc/default/grub.backup

# Configure GRUB command line
GRUB_CMDLINE="cryptdevice=UUID=${CRYPT_UUID}:lvm-system:allow-discards root=UUID=${ROOT_UUID} loglevel=3 quiet"
if [[ -n "$SWAP_UUID" ]]; then
    GRUB_CMDLINE="${GRUB_CMDLINE} resume=UUID=${SWAP_UUID}"
fi
GRUB_CMDLINE="${GRUB_CMDLINE} net.ifnames=0"

# Update GRUB_CMDLINE_LINUX_DEFAULT
sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE}\"/" /etc/default/grub
sed -i "s/^GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES=\"part_gpt part_msdos cryptodisk\"/" /etc/default/grub
sed -i "s/^\#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/" /etc/default/grub
print_success "GRUB configuration updated"

# Determine boot mode
if [[ -d /sys/firmware/efi/efivars ]]; then
    BOOT_MODE="UEFI"
    print_info "UEFI system detected"
else
    BOOT_MODE="Legacy"
    print_info "Legacy BIOS system detected"
fi

# Ask user to confirm or override
echo "Detected boot mode: $BOOT_MODE"
read -p "Is this correct? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "1) UEFI"
    echo "2) Legacy BIOS"
    read -p "Select boot mode (1 or 2): " -n 1 -r
    echo
    case $REPLY in
        1) BOOT_MODE="UEFI" ;;
        2) BOOT_MODE="Legacy" ;;
        *) print_error "Invalid selection"; exit 1 ;;
    esac
fi

# Install GRUB
print_info "Installing GRUB for $BOOT_MODE system..."
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    # Check if /boot is mounted and is EFI system partition
    if ! mountpoint -q /boot; then
        print_error "/boot is not mounted. Please mount your EFI system partition to /boot"
        exit 1
    fi
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=artix --recheck
else
    grub-install --target=i386-pc --boot-directory=/boot --bootloader-id=artix --recheck /dev/$DISK_NAME
fi

# Generate GRUB config
grub-mkconfig -o /boot/grub/grub.cfg
print_success "GRUB installed and configured"

# Set root password
print_header "ROOT PASSWORD"
while ! passwd; do
    print_error "Failed to set password. Please try again."
done

# Enable NetworkManager
print_info "Enabling NetworkManager..."
ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/
print_success "NetworkManager enabled"

print_success "Chroot configuration completed!"
print_header "POST-INSTALLATION RECOMMENDATIONS"
echo "After reboot, consider these additional steps:"
echo "1. Create a regular user account"
echo "2. Install and configure a desktop environment"
echo "3. Install additional software"
echo "4. Configure firewall"
echo "5. Update the system: pacman -Syu"

CHROOT_EOF

    # Make the chroot script executable
    chmod +x /mnt/chroot_config.sh
}

execute_chroot_configuration() {
    # Execute the chroot script
    print_info "Entering chroot environment for system configuration..."
    artix-chroot /mnt /chroot_config.sh

    # Clean up
    rm /mnt/chroot_config.sh
}

show_completion_info() {
    print_header "INSTALLATION COMPLETED"

    # Determine partition name (handle nvme vs sda naming)
    local PARTITION
    if [[ "$DISK" =~ nvme[0-9]+n[0-9]+ ]]; then
        PARTITION="${DISK}p1"
    else
        PARTITION="${DISK}1"
    fi

    echo "Disk: $DISK"
    echo "Encryption: LUKS1 with Serpent-XTS-Plain64"
    echo "LVM Volume Group: lvmSystem"
    echo "Logical Volumes:"
    echo "  - volBoot ($BOOT_SIZE) - FAT32"
    echo "  - volSwap ($SWAP_SIZE)"
    echo "  - volRoot (remaining space) - BTRFS"
    echo ""
    echo "Important UUIDs:"
    echo "Encrypted partition UUID: $(blkid -s UUID -o value $PARTITION)"
    echo "Swap UUID: $SWAP_UUID"
    echo ""

    print_success "Artix Linux installation completed successfully!"
    print_info "You can now reboot into your new system."
    print_warning "Don't forget to:"
    echo "1. Remove installation media"
    echo "2. Create a regular user account after first boot"
    echo "3. Update the system: pacman -Syu"
    echo ""
    echo "Cleanup commands (if needed):"
    echo "  umount -R /mnt"
    echo "  swapoff -a"
    echo "  vgchange -an lvmSystem"
    echo "  cryptsetup luksClose lvm-system"
    echo "  sync"
}

#=============================================================================
# MAIN EXECUTION
#=============================================================================

main() {
    print_header "ARTIX LINUX COMPLETE INSTALLATION"
    echo "This script will:"
    echo "1. Securely erase your selected disk (optional)"
    echo "2. Create and encrypt partitions with LUKS"
    echo "3. Set up LVM with boot, swap, and root volumes"
    echo "4. Format partitions (BTRFS for root, FAT32 for boot)"
    echo "5. Install base Artix Linux system"
    echo "6. Configure bootloader and system settings"
    echo ""
    print_warning "This is a destructive operation. Make sure you have backups!"
    echo ""

    # Phase 1: Disk encryption setup
    check_root
    get_disk_configuration
    confirm_configuration
    downgrade_parted

    # Ask about secure erase and perform accordingly
    if ask_secure_erase; then
        erase_disk
    else
        quick_erase
    fi

    create_partition
    setup_encryption
    setup_lvm
    format_partitions
    mount_partitions

    # Phase 2: System installation
    install_base_system
    create_chroot_script
    execute_chroot_configuration

    # Show completion information
    show_completion_info

    # Ask about reboot
    echo ""
    read -p "Would you like to reboot now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Rebooting..."
        reboot
    else
        print_info "Installation completed. Reboot when ready."
    fi
}

# Run the main function
main "$@"
