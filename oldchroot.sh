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
print_success "mkinitcpio configured and initramfs generated"

# Configure GRUB
print_header "BOOTLOADER CONFIGURATION"

# Determine which partition contains the encrypted LVM
# Check if volBoot exists to determine boot setup
if lvdisplay /dev/lvmSystem/volBoot &>/dev/null; then
    BOOT_ENCRYPTED="true"
    print_info "Detected encrypted boot setup"
    # Encrypted partition is partition 1
    if [[ "$DISK_NAME" =~ nvme[0-9]+n[0-9]+ ]]; then
        CRYPT_PARTITION="/dev/${DISK_NAME}p1"
    else
        CRYPT_PARTITION="/dev/${DISK_NAME}1"
    fi
else
    BOOT_ENCRYPTED="false"
    print_info "Detected unencrypted boot setup"
    # Encrypted partition is partition 2
    if [[ "$DISK_NAME" =~ nvme[0-9]+n[0-9]+ ]]; then
        CRYPT_PARTITION="/dev/${DISK_NAME}p2"
    else
        CRYPT_PARTITION="/dev/${DISK_NAME}2"
    fi
fi

# Get UUIDs
CRYPT_UUID=$(blkid -s UUID -o value "$CRYPT_PARTITION")
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
echo "  Boot encrypted: $BOOT_ENCRYPTED"

# Backup original GRUB config
cp /etc/default/grub /etc/default/grub.backup

# Configure GRUB command line
GRUB_CMDLINE="cryptdevice=UUID=${CRYPT_UUID}:lvm-system:allow-discards root=UUID=${ROOT_UUID} loglevel=3 quiet"
if [[ -n "$SWAP_UUID" ]]; then
    GRUB_CMDLINE="${GRUB_CMDLINE} resume=UUID=${SWAP_UUID}"
fi
GRUB_CMDLINE="${GRUB_CMDLINE} net.ifnames=0"

# FIXED: Escape special characters and use safer delimiters
GRUB_CMDLINE_ESCAPED=$(printf '%s\n' "$GRUB_CMDLINE" | sed 's/[[\.*^$()+?{|]/\\&/g')

# Update GRUB configuration with safer sed commands
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_ESCAPED}\"|" /etc/default/grub

# Only enable cryptodisk for encrypted boot
if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
    sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos cryptodisk"|' /etc/default/grub
    sed -i 's|^#GRUB_ENABLE_CRYPTODISK=.*|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
else
    # For unencrypted boot, we don't need cryptodisk in GRUB
    sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos"|' /etc/default/grub
    sed -i 's|^GRUB_ENABLE_CRYPTODISK=.*|#GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
fi

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
print_header "Recompiling Kernel"
mkinitcpio -P
