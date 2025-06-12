#!/bin/bash
# Artix Full Disk Encryption Setup Script
# This script performs disk partitioning and encryption setup for Artix Linux
# Use at your own risk and make sure you understand what it does before running

set -e  # Exit on error
set -u  # Treat unset variables as errors

# Variables that will be set by user input
DISK=""
BOOT_SIZE=""
SWAP_SIZE=""
REGION=""
CITY=""
HOSTNAME=""


# Functions
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi
}

show_available_disks() {
    echo "Available disks:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
    echo ""
}

get_user_input() {
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
        if [ -b "$DISK" ]; then
            break
        else
            echo "Error: Disk $DISK does not exist. Please try again."
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
        echo "Warning: Boot size should include units (G/M/K). Assuming gigabytes."
        BOOT_SIZE="${BOOT_SIZE}G"
    fi

    if [[ ! "$SWAP_SIZE" =~ [0-9]+[GMK]$ ]]; then
        echo "Warning: Swap size should include units (G/M/K). Assuming gigabytes."
        SWAP_SIZE="${SWAP_SIZE}G"
    fi
}

confirm_configuration() {
    echo ""
    echo "===== Configuration Summary ====="
    echo "Disk: $DISK"
    echo "Boot partition size: $BOOT_SIZE"
    echo "Swap partition size: $SWAP_SIZE"
    echo "Root partition: Uses remaining space"
    echo "Root filesystem: BTRFS"
    echo ""

    lsblk "$DISK"
    echo ""
    echo "WARNING: This will COMPLETELY ERASE disk $DISK"
    echo "ALL DATA ON THIS DISK WILL BE LOST!"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Operation canceled."
        exit 0
    fi
}

ask_secure_erase() {
    echo ""
    echo "===== Secure Disk Erase Option ====="
    echo "A secure erase will overwrite the entire disk with encrypted random data."
    echo "This is recommended for security but takes significant time."
    echo ""
    echo "Options:"
    echo "1. Perform secure erase (RECOMMENDED for security)"
    echo "2. Skip secure erase (faster, but less secure)"
    echo ""
    read -p "Do you want to perform a secure erase? (Y/n): " erase_choice

    if [[ "$erase_choice" == "n" || "$erase_choice" == "N" ]]; then
        echo "Skipping secure erase. Only clearing partition table..."
        return 1  # Return false to skip secure erase
    else
        echo "Proceeding with secure erase..."
        return 0  # Return true to perform secure erase
    fi
}

quick_erase() {
    echo "Performing quick erase (clearing partition table and filesystem signatures)..."

    # Clear partition table and first few MB
    dd bs=1M if=/dev/zero of="$DISK" count=10 status=progress || true
    sync

    # Clear the end of the disk (backup partition tables)
    local DISK_SIZE
    DISK_SIZE=$(blockdev --getsize64 "$DISK")
    local END_OFFSET=$(( DISK_SIZE - 10*1024*1024 ))  # Last 10MB

    dd bs=1M if=/dev/zero of="$DISK" seek=$((END_OFFSET/1024/1024)) count=10 status=progress || true
    sync

    echo "Quick erase completed."
}

downgrade_parted() {
    echo "Downgrading parted to avoid 'unknown filesystem' error..."
    pacman -U "https://archive.artixlinux.org/packages/p/parted/parted-3.4-2-x86_64.pkg.tar.zst" --noconfirm || {
        echo "Warning: Could not downgrade parted. Continuing anyway..."
    }
}

erase_disk() {
    echo "Erasing disk $DISK (this may take a while)..."

    # Get disk size to ensure we don't try to write more than its capacity
    local DISK_SIZE
    DISK_SIZE=$(blockdev --getsize64 "$DISK")
    local BLOCK_SIZE=4096

    # First pass with zeros (limited to first 100MB for speed)
    echo "First pass: Writing zeros to first 100MB of disk..."
    dd bs=$BLOCK_SIZE if=/dev/zero of="$DISK" oflag=direct status=progress count=$((100*1024*1024/BLOCK_SIZE)) || true
    sync

    # Second pass with encrypted zeros (faster than /dev/urandom but cryptographically secure)
    echo "Second pass: Writing encrypted data to disk for secure erasure..."
    local PASS
    PASS=$(tr -cd '[:alnum:]' < /dev/urandom | head -c128)
    echo "Using OpenSSL AES-256-CTR for efficient secure erase..."

    # Use a pipe to prevent errors from stopping the process
    set +e  # Temporarily disable exit on error
    openssl enc -aes-256-ctr -pass pass:"$PASS" -nosalt </dev/zero |
        dd bs=64K of="$DISK" oflag=direct status=progress 2>&1 |
        grep -v "No space left on device" || true
    set -e  # Re-enable exit on error

    # Ensure sync after write
    sync

    echo "Disk erasure completed."
}

create_partition() {
    echo "Creating partition on $DISK..."
    parted -s "$DISK" mklabel msdos
    parted -s -a optimal "$DISK" mkpart "primary" "btrfs" "0%" "100%"
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" set 1 lvm on
    parted -s "$DISK" print

    # Verify alignment
    local alignment_ok
    alignment_ok=$(parted -s "$DISK" align-check optimal 1)
    echo "Partition alignment: $alignment_ok"

    # Flush partition table to disk
    partprobe "$DISK"
    sync

    # Wait for partition to be recognized
    sleep 2

    echo "Partition created: ${DISK}1"
}

setup_encryption() {
    echo "Setting up disk encryption..."

    # Check for serpent cipher support
    if ! grep -q "serp" /proc/crypto; then
        echo "WARNING: Serpent cipher not found in kernel. You may need to load the appropriate module."
        echo "Available ciphers:"
        grep "name" /proc/crypto | sort | uniq
    fi

    # Show encryption benchmark
    echo "Running encryption benchmark..."
    cryptsetup benchmark

    # Create LUKS container
    echo ""
    echo "Creating LUKS container on ${DISK}1..."
    echo "You will be prompted to enter a passphrase for disk encryption."
    echo "IMPORTANT: Choose a strong passphrase and remember it - you'll need it to boot your system!"
    echo ""

    cryptsetup --verbose --type luks1 --cipher serpent-xts-plain64 --key-size 512 \
               --hash sha512 --iter-time 10000 --use-random --verify-passphrase luksFormat "${DISK}1"

    # Open LUKS container
    echo "Opening LUKS container..."
    cryptsetup luksOpen "${DISK}1" lvm-system

    echo "Encryption setup completed. LUKS container is now open as /dev/mapper/lvm-system"
}

setup_lvm() {
    echo "Setting up LVM..."
    pvcreate /dev/mapper/lvm-system
    vgcreate lvmSystem /dev/mapper/lvm-system

    # Create logical volumes with user-specified sizes
    echo "Creating logical volumes..."
    lvcreate --contiguous y --size "$BOOT_SIZE" lvmSystem --name volBoot
    lvcreate --contiguous y --size "$SWAP_SIZE" lvmSystem --name volSwap
    lvcreate --contiguous y --extents +100%FREE lvmSystem --name volRoot

    # Show created volumes
    echo "Created logical volumes:"
    lvs
}

format_partitions() {
    echo "Formatting partitions..."

    # Format boot partition as FAT32
    echo "Formatting boot partition (FAT32)..."
    mkfs.fat -F32 -n BOOT /dev/lvmSystem/volBoot

    # Create swap partition
    echo "Creating swap partition..."
    mkswap -L SWAP /dev/lvmSystem/volSwap

    # Get swap UUID and save it for later use
    SWAP_UUID=$(blkid -s UUID -o value /dev/lvmSystem/volSwap)
    echo "SWAP UUID: $SWAP_UUID (save this for later)"

    # Format root partition as BTRFS
    echo "Creating BTRFS root filesystem..."
    mkfs.btrfs -f -L ROOT /dev/lvmSystem/volRoot

    echo "All partitions formatted successfully."
}

mount_partitions() {
    echo "Mounting partitions..."

    # Activate swap
    swapon /dev/lvmSystem/volSwap

    # Mount root partition
    mount /dev/lvmSystem/volRoot /mnt

    # Create boot directory and mount boot partition
    mkdir -p /mnt/boot
    mount /dev/lvmSystem/volBoot /mnt/boot

    echo "Partitions mounted successfully:"
    echo "  Root (BTRFS): /mnt"
    echo "  Boot (FAT32): /mnt/boot"
    echo "  Swap: activated"
}

show_configuration_info() {
    echo ""
    echo "===== Setup Complete ====="
    echo "Disk: $DISK"
    echo "Encryption: LUKS1 with Serpent-XTS-Plain64"
    echo "LVM Volume Group: lvmSystem"
    echo "Logical Volumes:"
    echo "  - volBoot ($BOOT_SIZE) - FAT32"
    echo "  - volSwap ($SWAP_SIZE)"
    echo "  - volRoot (remaining space) - BTRFS"
    echo ""
    echo "Important UUIDs for configuration:"
    echo "Root partition UUID: $(blkid -s UUID -o value ${DISK}1)"
    echo "Swap UUID: $SWAP_UUID"
    echo ""
    echo "Mounted filesystems:"
    df -h | grep -E "(lvmSystem|/mnt)"
    echo ""
    echo "Next steps:"
    echo "1. Install your base system to /mnt"
    echo "2. Configure /etc/mkinitcpio.conf to include 'encrypt' hook before 'lvm2'"
    echo "3. Configure GRUB with proper cryptdevice parameters"
    echo "4. Install and configure bootloader"
    echo ""
    echo "Example GRUB configuration:"



    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$(blkid -s UUID -o value ${DISK}1):lvm-system:allow-discards UUID=$(blkid -s UUID -o value /dev/mapper/lvmSystem-volRoot):root loglevel=3 quiet resume=UUID=$(blkid -s UUID -o /dev/mapper/lvmSystem-volSwap) net.ifnames=0\""


}

show_cleanup_commands() {
    echo ""
    echo "When finished, run these commands to unmount and close everything:"
    echo "  umount -R /mnt"
    echo "  swapoff -a"
    echo "  vgchange -an lvmSystem"
    echo "  cryptsetup luksClose lvm-system"
    echo "  sync"
}

# Main execution
main() {
    echo "===== Artix Disk Encryption and Partitioning Setup ====="
    echo "This script will:"
    echo "1. Securely erase your selected disk"
    echo "2. Create a single partition"
    echo "3. Encrypt the partition with LUKS"
    echo "4. Set up LVM with boot, swap, and root volumes"
    echo "5. Format partitions (BTRFS for root, FAT32 for boot)"
    echo "6. Mount the filesystems"
    echo ""

    # Run the setup process
    check_root
    get_user_input
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
    show_configuration_info
    show_cleanup_commands
}

# Run the main function
main "$@"
