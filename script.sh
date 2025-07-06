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
DISK_NAME=""
BOOT_SIZE=""
SWAP_SIZE=""
SWAP_UUID=""
BOOT_ENCRYPTED="true"  # Default to encrypted boot
TIMEZONE=""
HOSTNAME=""
REGION=""
CITY=""

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

validate_hostname() {
    # Check if hostname is valid (RFC 1123)
    if [[ ${#1} -gt 63 ]]; then
        print_error "Hostname too long (max 63 characters)"
        return 1
    fi
    if [[ ! "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        print_error "Invalid hostname format. Use only letters, numbers, and hyphens. Cannot start or end with hyphen."
        return 1
    fi
    return 0
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
            DISK_NAME="${disk_input#/dev/}"
        else
            DISK="/dev/$disk_input"
            DISK_NAME="$disk_input"
        fi

        # Check if disk exists
        if [[ -b "$DISK" ]]; then
            break
        else
            print_error "Disk $DISK does not exist. Please try again."
            show_available_disks
        fi
    done

    # Ask about boot partition encryption
    print_header "BOOT PARTITION CONFIGURATION"
    echo "Choose boot partition setup:"
    echo "1. Encrypted boot (inside LVM) - More secure but potentially more complex"
    echo "2. Unencrypted boot (separate partition) - Simpler, widely compatible"
    echo ""
    while true; do
        read -p "Select option (1 or 2): " boot_choice
        case $boot_choice in
            1)
                BOOT_ENCRYPTED="true"
                print_info "Selected: Encrypted boot partition (inside LVM)"
                break
                ;;
            2)
                BOOT_ENCRYPTED="false"
                print_info "Selected: Unencrypted boot partition (separate)"
                break
                ;;
            *)
                print_error "Invalid choice. Please enter 1 or 2."
                ;;
        esac
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

get_system_configuration() {
    print_header "SYSTEM CONFIGURATION"

    # Get timezone
    echo "Available regions:"
    ls /usr/share/zoneinfo/ | grep -E '^[A-Z]' | head -10
    echo "..."

    while true; do
        get_user_input "Enter your region (e.g., America, Europe, Asia)" REGION
        if [[ -d "/usr/share/zoneinfo/$REGION" ]]; then
            break
        else
            print_error "Invalid region '$REGION'. Please choose from available regions."
            echo "Available regions:"
            ls /usr/share/zoneinfo/ | grep -E '^[A-Z]' | head -20
            echo "..."
        fi
    done

    echo "Available cities in $REGION:"
    ls "/usr/share/zoneinfo/$REGION" | head -10
    echo "..."

    while true; do
        get_user_input "Enter your city" CITY
        TIMEZONE="$REGION/$CITY"

        if validate_timezone "$TIMEZONE"; then
            print_success "Timezone will be set to $TIMEZONE"
            break
        else
            print_error "Invalid city '$CITY' for region '$REGION'."
            echo "Available cities in $REGION:"
            ls "/usr/share/zoneinfo/$REGION" | head -20
            echo "..."
        fi
    done

    # Get hostname
    while true; do
        get_user_input "Enter hostname for this system" HOSTNAME validate_hostname
        if validate_hostname "$HOSTNAME"; then
            break
        fi
    done
}

confirm_configuration() {
    print_header "CONFIGURATION SUMMARY"
    echo "Disk: $DISK"
    echo "Boot partition size: $BOOT_SIZE"
    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        echo "Boot partition: Encrypted (inside LVM)"
    else
        echo "Boot partition: Unencrypted (separate partition)"
    fi
    echo "Swap partition size: $SWAP_SIZE"
    echo "Root partition: Uses remaining space"
    echo "Root filesystem: BTRFS"
    echo "Timezone: $TIMEZONE"
    echo "Hostname: $HOSTNAME"
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

create_partitions() {
    print_info "Creating partitions on $DISK..."

    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        # Single partition for encrypted LVM (original behavior)
        parted -s "$DISK" mklabel msdos
        parted -s -a optimal "$DISK" mkpart "primary" "btrfs" "0%" "100%"
        parted -s "$DISK" set 1 boot on
        parted -s "$DISK" set 1 lvm on
    else
        # Two partitions: unencrypted boot + encrypted LVM
        parted -s "$DISK" mklabel msdos
        # Boot partition
        parted -s -a optimal "$DISK" mkpart "primary" "fat32" "0%" "$BOOT_SIZE"
        parted -s "$DISK" set 1 boot on
        # LVM partition (rest of disk)
        parted -s -a optimal "$DISK" mkpart "primary" "ext4" "$BOOT_SIZE" "100%"
        parted -s "$DISK" set 2 lvm on
    fi

    parted -s "$DISK" print

    # Verify alignment
    local alignment_ok
    alignment_ok=$(parted -s "$DISK" align-check optimal 1)
    print_info "Partition 1 alignment: $alignment_ok"

    if [[ "$BOOT_ENCRYPTED" == "false" ]]; then
        alignment_ok=$(parted -s "$DISK" align-check optimal 2)
        print_info "Partition 2 alignment: $alignment_ok"
    fi

    # Flush partition table to disk
    partprobe "$DISK"
    sync

    # Wait for partitions to be recognized
    sleep 2

    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        print_success "Single partition created for encrypted setup: ${DISK}1"
    else
        print_success "Partitions created:"
        print_success "  Boot (unencrypted): ${DISK}1"
        print_success "  LVM (to be encrypted): ${DISK}2"
    fi
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

    # Determine which partition to encrypt
    local ENCRYPT_PARTITION
    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        # Encrypt the single partition
        if [[ "$DISK" =~ nvme[0-9]+n[0-9]+ ]]; then
            ENCRYPT_PARTITION="${DISK}p1"
        else
            ENCRYPT_PARTITION="${DISK}1"
        fi
    else
        # Encrypt the second partition (LVM partition)
        if [[ "$DISK" =~ nvme[0-9]+n[0-9]+ ]]; then
            ENCRYPT_PARTITION="${DISK}p2"
        else
            ENCRYPT_PARTITION="${DISK}2"
        fi
    fi

    # Create LUKS container
    echo ""
    print_info "Creating LUKS container on $ENCRYPT_PARTITION..."
    print_warning "You will be prompted to enter a passphrase for disk encryption."
    print_warning "IMPORTANT: Choose a strong passphrase and remember it - you'll need it to boot your system!"
    echo ""

    cryptsetup --verbose --type luks1 --cipher serpent-xts-plain64 --key-size 512 \
               --hash sha512 --iter-time 10000 --use-random --verify-passphrase luksFormat "$ENCRYPT_PARTITION"

    # Open LUKS container
    print_info "Opening LUKS container..."
    cryptsetup luksOpen "$ENCRYPT_PARTITION" lvm-system

    print_success "Encryption setup completed. LUKS container is now open as /dev/mapper/lvm-system"
}

setup_lvm() {
    print_info "Setting up LVM..."
    pvcreate /dev/mapper/lvm-system
    vgcreate lvmSystem /dev/mapper/lvm-system

    # Create logical volumes based on boot encryption choice
    print_info "Creating logical volumes..."

    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        # Original behavior: boot inside LVM
        lvcreate --contiguous y --size "$BOOT_SIZE" lvmSystem --name volBoot
        lvcreate --contiguous y --size "$SWAP_SIZE" lvmSystem --name volSwap
        lvcreate --contiguous y --extents +100%FREE lvmSystem --name volRoot
    else
        # New behavior: no boot in LVM (boot is separate unencrypted partition)
        lvcreate --contiguous y --size "$SWAP_SIZE" lvmSystem --name volSwap
        lvcreate --contiguous y --extents +100%FREE lvmSystem --name volRoot
    fi

    # Show created volumes
    print_info "Created logical volumes:"
    lvs

    print_success "LVM setup completed"
}

format_partitions() {
    print_info "Formatting partitions..."

    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        # Format boot partition inside LVM as FAT32
        print_info "Formatting encrypted boot partition (FAT32)..."
        mkfs.fat -F32 -n BOOT /dev/lvmSystem/volBoot
    else
        # Format separate unencrypted boot partition as FAT32
        print_info "Formatting unencrypted boot partition (FAT32)..."
        local BOOT_PARTITION
        if [[ "$DISK" =~ nvme[0-9]+n[0-9]+ ]]; then
            BOOT_PARTITION="${DISK}p1"
        else
            BOOT_PARTITION="${DISK}1"
        fi
        mkfs.fat -F32 -n BOOT "$BOOT_PARTITION"
    fi

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

    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        # Mount encrypted boot from LVM
        mount /dev/lvmSystem/volBoot /mnt/boot
        print_success "Partitions mounted successfully:"
        echo "  Root (BTRFS): /mnt"
        echo "  Boot (FAT32, encrypted): /mnt/boot"
        echo "  Swap: activated"
    else
        # Mount unencrypted boot partition
        local BOOT_PARTITION
        if [[ "$DISK" =~ nvme[0-9]+n[0-9]+ ]]; then
            BOOT_PARTITION="${DISK}p1"
        else
            BOOT_PARTITION="${DISK}1"
        fi
        mount "$BOOT_PARTITION" /mnt/boot
        print_success "Partitions mounted successfully:"
        echo "  Root (BTRFS): /mnt"
        echo "  Boot (FAT32, unencrypted): /mnt/boot"
        echo "  Swap: activated"
    fi
}

#=============================================================================
# PHASE 2: SYSTEM INSTALLATION
#=============================================================================

install_base_system() {
    print_header "Changing Pacman for speed"
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
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

configure_system() {
    print_header "SYSTEM CONFIGURATION"

    # Set timezone
    print_info "Setting timezone to $TIMEZONE..."
    if artix-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime; then
        print_success "Timezone set to $TIMEZONE"
    else
        print_error "Failed to set timezone"
        exit 1
    fi

    # Sync hardware clock
    print_info "Syncing hardware clock..."
    if artix-chroot /mnt hwclock --systohc 2>/dev/null; then
        print_success "Hardware clock synced"
    else
        print_warning "Failed to sync hardware clock. This may not be critical."
    fi

    # Set up locale
    print_info "Setting up locale..."
    artix-chroot /mnt /bin/bash -c 'cat > /etc/locale.conf << "LOCALE_EOF"
LANG=en_US.UTF-8
export LC_COLLATE="C"
LOCALE_EOF'

    artix-chroot /mnt /bin/bash -c 'echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen'

    if artix-chroot /mnt locale-gen; then
        print_success "Locale configured"
    else
        print_error "Failed to generate locale"
        exit 1
    fi

    # Set hostname
    print_info "Setting hostname to $HOSTNAME..."
    artix-chroot /mnt /bin/bash -c "echo '$HOSTNAME' > /etc/hostname"

    artix-chroot /mnt /bin/bash -c "cat > /etc/hosts << HOSTS_EOF
127.0.0.1    localhost
::1          localhost
127.0.1.1    $HOSTNAME.localdomain $HOSTNAME
HOSTS_EOF"

    print_success "Hostname set to $HOSTNAME"

    # Configure mkinitcpio
    print_info "Configuring mkinitcpio..."
    artix-chroot /mnt cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.backup

    artix-chroot /mnt sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt keyboard keymap consolefont lvm2 filesystems fsck)/' /etc/mkinitcpio.conf

    print_success "mkinitcpio configured"
}

configure_bootloader() {
    print_header "BOOTLOADER CONFIGURATION"

    # Determine which partition contains the encrypted LVM
    local CRYPT_PARTITION
    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        print_info "Configuring for encrypted boot setup"
        # Encrypted partition is partition 1
        if [[ "$DISK" =~ nvme[0-9]+n[0-9]+ ]]; then
            CRYPT_PARTITION="${DISK}p1"
        else
            CRYPT_PARTITION="${DISK}1"
        fi
    else
        print_info "Configuring for unencrypted boot setup"
        # Encrypted partition is partition 2
        if [[ "$DISK" =~ nvme[0-9]+n[0-9]+ ]]; then
            CRYPT_PARTITION="${DISK}p2"
        else
            CRYPT_PARTITION="${DISK}2"
        fi
    fi

    # Get UUIDs
    print_info "Detecting partition UUIDs..."
    local CRYPT_UUID ROOT_UUID
    CRYPT_UUID=$(blkid -s UUID -o value "$CRYPT_PARTITION" 2>/dev/null)
    ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/lvmSystem-volRoot 2>/dev/null)

    if [[ -z "$CRYPT_UUID" ]]; then
        print_error "Could not determine UUID for encrypted partition: $CRYPT_PARTITION"
        exit 1
    fi

    if [[ -z "$ROOT_UUID" ]]; then
        print_error "Could not determine UUID for root partition: /dev/mapper/lvmSystem-volRoot"
        exit 1
    fi

    print_info "Found UUIDs:"
    echo "  Encrypted partition: $CRYPT_UUID"
    echo "  Root partition: $ROOT_UUID"
    [[ -n "$SWAP_UUID" ]] && echo "  Swap partition: $SWAP_UUID"

    # Configure GRUB
    artix-chroot /mnt cp /etc/default/grub /etc/default/grub.backup

    # Build GRUB command line
    local GRUB_CMDLINE="cryptdevice=UUID=${CRYPT_UUID}:lvm-system:allow-discards root=UUID=${ROOT_UUID} loglevel=3 quiet"
    if [[ -n "$SWAP_UUID" ]]; then
        GRUB_CMDLINE="${GRUB_CMDLINE} resume=UUID=${SWAP_UUID}"
    fi
    GRUB_CMDLINE="${GRUB_CMDLINE} net.ifnames=0"

    # Update GRUB configuration
    artix-chroot /mnt /bin/bash -c "sed -i \"s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\\\"$GRUB_CMDLINE\\\"|\" /etc/default/grub"

    # Configure cryptodisk based on boot encryption
    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        artix-chroot /mnt sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos cryptodisk"|' /etc/default/grub
        artix-chroot /mnt sed -i 's|^#GRUB_ENABLE_CRYPTODISK=.*|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
    else
        artix-chroot /mnt sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos"|' /etc/default/grub
        artix-chroot /mnt sed -i 's|^GRUB_ENABLE_CRYPTODISK=.*|#GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
    fi

    print_success "GRUB configuration updated"

    # Determine boot mode
    local BOOT_MODE
    if [[ -d /sys/firmware/efi/efivars ]]; then
        BOOT_MODE="UEFI"
        print_info "UEFI system detected"
    else
        BOOT_MODE="Legacy"
        print_info "Legacy BIOS system detected"
    fi

    # Ask user to confirm or override
    echo "Detected boot mode: $BOOT_MODE"
    while true; do
        read -p "Is this correct? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            break
        elif [[ $REPLY =~ ^[Nn]$ ]]; then
            echo "1) UEFI"
            echo "2) Legacy BIOS"
            while true; do
                read -p "Select boot mode (1 or 2): " -n 1 -r
                echo
                case $REPLY in
                    1) BOOT_MODE="UEFI"; break 2 ;;
                    2) BOOT_MODE="Legacy"; break 2 ;;
                    *) print_error "Invalid selection. Please enter 1 or 2." ;;
                esac
            done
        else
            print_error "Please answer 'y' for yes or 'n' for no."
        fi
    done

    # Install GRUB
    print_info "Installing GRUB for $BOOT_MODE system..."
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        if artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=artix --recheck; then
            print_success "GRUB installed for UEFI"
        else
            print_error "Failed to install GRUB for UEFI"
            exit 1
        fi
    else
        if artix-chroot /mnt grub-install --target=i386-pc --boot-directory=/boot --bootloader-id=artix --recheck "/dev/$DISK_NAME"; then
            print_success "GRUB installed for Legacy BIOS"
        else
            print_error "Failed to install GRUB for Legacy BIOS"
            exit 1
        fi
    fi

    # Generate GRUB config
    if artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg; then
        print_success "GRUB configuration generated"
    else
        print_error "Failed to generate GRUB configuration"
        exit 1
    fi
}

configure_user_settings() {
    print_header "USER SETTINGS"

    # Set root password
    print_info "Setting root password..."
    while true; do
        if artix-chroot /mnt passwd; then
            print_success "Root password set successfully"
            break
        else
            print_error "Failed to set password. Please try again."
            read -p "Do you want to try again? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_warning "Skipping root password setup. You can set it later with 'passwd' command."
                break
            fi
        fi
    done

    # Enable NetworkManager
    print_info "Enabling NetworkManager..."
    if artix-chroot /mnt ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/ 2>/dev/null; then
        print_success "NetworkManager enabled"
    else
        if [[ -L /mnt/etc/runit/runsvdir/default/NetworkManager ]]; then
            print_warning "NetworkManager is already enabled"
        else
            print_error "Failed to enable NetworkManager"
            exit 1
        fi
    fi

    # Generate initramfs
    print_info "Generating initramfs..."
    if artix-chroot /mnt mkinitcpio -P; then
        print_success "Initramfs generated successfully"
    else
        print_error "Failed to generate initramfs"
        exit 1
    fi
}

create_user_account() {
    print_header "CREATE USER ACCOUNT"

    # Ask if user wants to create a user account
    while true; do
        read -p "Do you want to create a user account? (Y/n): " create_user
        case $create_user in
            [Yy]* | "" )
                break
                ;;
            [Nn]* )
                print_info "Skipping user account creation."
                return 0
                ;;
            * )
                print_error "Please answer yes or no."
                ;;
        esac
    done

    # Get username
    while true; do
        read -p "Enter username: " username
        if [[ -n "$username" ]] && [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            break
        else
            print_error "Invalid username. Use only lowercase letters, numbers, underscore, and hyphen."
            print_error "Must start with a letter or underscore."
        fi
    done

    # Create user account
    print_info "Creating user account '$username'..."
    if artix-chroot /mnt useradd -m -G wheel -s /bin/bash "$username"; then
        print_success "User account '$username' created"
    else
        print_error "Failed to create user account"
        exit 1
    fi

    # Set user password
    print_info "Setting password for user '$username'..."
    while true; do
        if artix-chroot /mnt passwd "$username"; then
            print_success "Password set for user '$username'"
            break
        else
            print_error "Failed to set password. Please try again."
            read -p "Do you want to try again? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_warning "Skipping password setup for '$username'. You can set it later."
                break
            fi
        fi
    done

    # Configure sudo
    print_info "Configuring sudo for wheel group..."
    artix-chroot /mnt /bin/bash -c "echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers"
    print_success "Sudo configured for wheel group"
}

install_additional_packages() {
    print_header "ADDITIONAL PACKAGES"

    # Ask if user wants to install additional packages
    while true; do
        read -p "Do you want to install additional packages? (Y/n): " install_extra
        case $install_extra in
            [Yy]* | "" )
                break
                ;;
            [Nn]* )
                print_info "Skipping additional package installation."
                return 0
                ;;
            * )
                print_error "Please answer yes or no."
                ;;
        esac
    done

    # Common package categories
    echo "Select package categories to install:"
    echo "1) Desktop Environment (XFCE)"
    echo "2) Development Tools (git, gcc, make, etc.)"
    echo "3) System Tools (htop, neofetch, tree, etc.)"
    echo "4) Media Tools (ffmpeg, mpv, etc.)"
    echo "5) Web Browser (firefox)"
    echo "6) All of the above"
    echo "7) Custom package list"
    echo "8) Skip"

    while true; do
        read -p "Enter your choice (1-8): " pkg_choice
        case $pkg_choice in
            1)
                EXTRA_PACKAGES="xfce4 xfce4-goodies lightdm lightdm-runit lightdm-gtk-greeter"
                break
                ;;
            2)
                EXTRA_PACKAGES="git gcc make cmake python python-pip nodejs npm"
                break
                ;;
            3)
                EXTRA_PACKAGES="htop neofetch tree unzip zip wget curl rsync"
                break
                ;;
            4)
                EXTRA_PACKAGES="ffmpeg mpv vlc gimp"
                break
                ;;
            5)
                EXTRA_PACKAGES="firefox"
                break
                ;;
            6)
                EXTRA_PACKAGES="xfce4 xfce4-goodies lightdm lightdm-runit lightdm-gtk-greeter git gcc make cmake python python-pip nodejs npm htop neofetch tree unzip zip wget curl rsync ffmpeg mpv vlc gimp firefox"
                break
                ;;
            7)
                read -p "Enter package names separated by spaces: " EXTRA_PACKAGES
                break
                ;;
            8)
                print_info "Skipping additional package installation."
                return 0
                ;;
            *)
                print_error "Invalid choice. Please enter 1-8."
                ;;
        esac
    done

    # Install packages
    if [[ -n "$EXTRA_PACKAGES" ]]; then
        print_info "Installing additional packages: $EXTRA_PACKAGES"
        if artix-chroot /mnt pacman -S --noconfirm $EXTRA_PACKAGES; then
            print_success "Additional packages installed successfully"

            # Enable lightdm if desktop environment was installed
            if [[ "$EXTRA_PACKAGES" == *"lightdm"* ]]; then
                print_info "Enabling lightdm display manager..."
                artix-chroot /mnt ln -s /etc/runit/sv/lightdm /etc/runit/runsvdir/default/ 2>/dev/null || true
                print_success "Lightdm enabled"
            fi
        else
            print_warning "Some packages may have failed to install. Check the output above."
        fi
    fi
}

cleanup_and_finish() {
    print_header "CLEANUP AND FINISH"

    # Unmount partitions
    print_info "Unmounting partitions..."
    umount -R /mnt 2>/dev/null || true
    swapoff -a 2>/dev/null || true

    # Close LUKS container
    print_info "Closing LUKS container..."
    cryptsetup luksClose lvm-system 2>/dev/null || true

    # Deactivate LVM
    print_info "Deactivating LVM..."
    vgchange -an lvmSystem 2>/dev/null || true

    print_success "Cleanup completed"
}

show_installation_summary() {
    print_header "INSTALLATION COMPLETE"

    echo ""
    print_success "Artix Linux installation completed successfully!"
    echo ""
    echo "System Configuration Summary:"
    echo "  Disk: $DISK"
    echo "  Boot: $(if [[ "$BOOT_ENCRYPTED" == "true" ]]; then echo "Encrypted"; else echo "Unencrypted"; fi)"
    echo "  Root filesystem: BTRFS"
    echo "  Encryption: LUKS1 with Serpent-XTS-Plain64"
    echo "  Hostname: $HOSTNAME"
    echo "  Timezone: $TIMEZONE"
    echo ""
    echo "Important Notes:"
    echo "- You will be prompted for your disk encryption password on boot"
    echo "- NetworkManager is enabled and will start automatically"
    echo "- Root password has been set"
    echo "- Additional user account may have been created"
    echo ""
    echo "Next Steps:"
    echo "1. Remove the installation media"
    echo "2. Reboot the system"
    echo "3. Log in with root or your user account"
    echo "4. Configure your system as needed"
    echo ""
    print_warning "Make sure to remember your disk encryption password!"
    echo ""
}

#=============================================================================
# MAIN EXECUTION
#=============================================================================

main() {
    print_header "ARTIX LINUX ENCRYPTED INSTALLATION"
    print_info "This script will install Artix Linux with full disk encryption"
    print_warning "This script will COMPLETELY ERASE the selected disk!"
    echo ""

    # Check if running as root
    check_root

    # Phase 1: Disk encryption setup
    get_disk_configuration
    get_system_configuration
    confirm_configuration

    # Optional secure erase
    if ask_secure_erase; then
        erase_disk
    else
        quick_erase
    fi

    # Downgrade parted to avoid issues
    downgrade_parted

    # Set up disk encryption
    create_partitions
    setup_encryption
    setup_lvm
    format_partitions
    mount_partitions

    # Phase 2: System installation
    install_base_system
    configure_system
    configure_bootloader
    configure_user_settings
    create_user_account
    install_additional_packages

    # Cleanup and finish
    cleanup_and_finish
    show_installation_summary

    print_success "Installation script completed successfully!"
    echo ""
    read -p "Press Enter to exit..."
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
