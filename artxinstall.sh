#!/bin/bash
#=============================================================================
# Artix Linux Encrypted Installation Script
#
# LUKS1 + LVM + BTRFS root, runit init.
#
# This version is written so that a bad input (wrong passphrase, typo, a
# command that fails) NEVER throws you back to the start. Every fallible
# step asks whether you want to retry.
#
# Use at your own risk. Read it before you run it.
#=============================================================================

set -uo pipefail   # NOTE: deliberately NOT 'set -e' -- see error handling below

#-----------------------------------------------------------------------------
# Colors
#-----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#-----------------------------------------------------------------------------
# Globals (all initialised so 'set -u' can't bite us)
#-----------------------------------------------------------------------------
DISK=""
DISK_NAME=""
BOOT_SIZE=""
SWAP_SIZE=""
SWAP_UUID=""
BOOT_ENCRYPTED="true"
TIMEZONE=""
HOSTNAME_VAL=""
FIRMWARE=""
PART_TABLE="msdos"
BOOT_MODE=""
LUKS_NAME="lvm-system"
VG_NAME="lvmSystem"
STORAGE_TOUCHED=0     # set to 1 once we have opened LUKS / mounted things

#-----------------------------------------------------------------------------
# Output helpers
#-----------------------------------------------------------------------------
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_header()  { echo -e "\n${BLUE}===== $1 =====${NC}"; }

#-----------------------------------------------------------------------------
# Error handling / cleanup
#-----------------------------------------------------------------------------

# Unwind mounts, swap, LVM and LUKS so the disk is left in a state where the
# script can simply be re-run from the top.
unwind_storage() {
    umount -R /mnt 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    vgchange -an "$VG_NAME" 2>/dev/null || true
    cryptsetup luksClose "$LUKS_NAME" 2>/dev/null || true
}

on_exit() {
    local code=$?
    if (( code != 0 )); then
        echo ""
        print_error "Script stopped (exit code $code)."
        if (( STORAGE_TOUCHED == 1 )); then
            print_info "Releasing mounts / LVM / LUKS so the disk is left clean..."
            unwind_storage
            print_info "Done. You can re-run this script from the beginning."
        fi
    fi
}
trap on_exit EXIT
trap 'echo ""; print_warning "Interrupted by user (Ctrl+C)."; exit 130' INT

# Fatal exit -- only used where continuing genuinely makes no sense.
die() {
    print_error "$1"
    exit 1
}

# Ask a yes/no question. Returns 0 for yes, 1 for no. Never dies.
#   ask_yes_no "Question?" y
ask_yes_no() {
    local prompt="$1" default="${2:-y}" answer hint
    if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        read -r -p "$prompt ($hint): " answer || answer=""
        answer="${answer,,}"
        [[ -z "$answer" ]] && answer="$default"
        case "$answer" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     print_error "Please answer 'y' or 'n'." ;;
        esac
    done
}

# Run a function/command; on failure offer to retry it. Returns 0 on success,
# 1 if the user gives up.
#   retry_step "Description" some_function
retry_step() {
    local desc="$1"; shift
    while true; do
        if "$@"; then
            return 0
        fi
        echo ""
        print_error "Step failed: $desc"
        if ask_yes_no "Retry this step?" y; then
            echo ""
            continue
        fi
        return 1
    done
}

# Read a value into a global, with an optional default.
#   prompt_default VARNAME "Prompt text" "default"
prompt_default() {
    local __var="$1" __prompt="$2" __default="${3:-}" __input=""
    if [[ -n "$__default" ]]; then
        read -r -p "$__prompt [$__default]: " __input || __input=""
        [[ -z "$__input" ]] && __input="$__default"
    else
        read -r -p "$__prompt: " __input || __input=""
    fi
    declare -g "$__var=$__input"
}

#-----------------------------------------------------------------------------
# Utility
#-----------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root."
}

check_dependencies() {
    local missing=() cmd
    for cmd in parted cryptsetup pvcreate vgcreate lvcreate mkfs.btrfs \
               mkfs.fat mkswap blkid lsblk basestrap fstabgen artix-chroot; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        print_error "Missing required commands: ${missing[*]}"
        print_info "Install them first, e.g.: pacman -Sy artix-installer-tools lvm2 cryptsetup parted dosfstools btrfs-progs"
        return 1
    fi
    return 0
}

# Correct partition path for both /dev/sda1 and /dev/nvme0n1p1 style names.
part() {
    if [[ "$DISK" =~ [0-9]$ ]]; then
        printf '%sp%s\n' "$DISK" "$1"
    else
        printf '%s%s\n' "$DISK" "$1"
    fi
}

detect_firmware() {
    if [[ -d /sys/firmware/efi/efivars ]]; then
        FIRMWARE="UEFI"
    else
        FIRMWARE="BIOS"
    fi
}

show_available_disks() {
    echo "Available disks:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
    echo ""
}

# "16G" -> MiB. Assumes the string already passed validate_size.
size_to_mib() {
    local s="${1^^}" num unit
    num="${s%[GMK]}"
    unit="${s: -1}"
    case "$unit" in
        G) echo $(( 10#$num * 1024 )) ;;
        M) echo $(( 10#$num )) ;;
        K) echo $(( 10#$num / 1024 )) ;;
        *) echo 0 ;;
    esac
}

validate_size() {
    [[ "$1" =~ ^[0-9]+[GMK]$ ]]
}

validate_hostname() {
    if [[ -z "$1" ]]; then
        print_error "Hostname cannot be empty."
        return 1
    fi
    if (( ${#1} > 63 )); then
        print_error "Hostname too long (max 63 characters)."
        return 1
    fi
    if [[ ! "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        print_error "Invalid hostname. Letters, numbers and hyphens only; cannot start or end with a hyphen."
        return 1
    fi
    return 0
}

#=============================================================================
# PHASE 0: CONFIGURATION (fully re-editable, nothing destructive happens yet)
#=============================================================================

get_disk_configuration() {
    print_header "DISK CONFIGURATION"
    show_available_disks

    # --- Disk selection ---
    while true; do
        local disk_input=""
        read -r -p "Enter the disk to use (e.g. sda, vda, nvme0n1): " disk_input
        if [[ -z "$disk_input" ]]; then
            print_error "No disk entered."
            continue
        fi

        if [[ "$disk_input" == /dev/* ]]; then
            DISK="$disk_input"
            DISK_NAME="${disk_input#/dev/}"
        else
            DISK="/dev/$disk_input"
            DISK_NAME="$disk_input"
        fi

        if [[ ! -b "$DISK" ]]; then
            print_error "$DISK is not a block device. Try again."
            show_available_disks
            continue
        fi

        # Refuse partitions -- we want a whole disk
        if [[ "$(lsblk -dno TYPE "$DISK" 2>/dev/null)" != "disk" ]]; then
            print_error "$DISK is not a whole disk (it looks like a partition). Try again."
            continue
        fi

        # Warn loudly if anything on this disk is currently mounted
        if lsblk -no MOUNTPOINT "$DISK" 2>/dev/null | grep -q '[^[:space:]]'; then
            print_warning "$DISK has mounted partitions:"
            lsblk -o NAME,SIZE,MOUNTPOINT "$DISK"
            print_warning "This may be your live/boot media."
            if ! ask_yes_no "Use $DISK anyway?" n; then
                continue
            fi
        fi
        break
    done

    # --- Boot partition style ---
    print_header "BOOT PARTITION CONFIGURATION"
    echo "Firmware detected: $FIRMWARE"
    echo ""
    echo "1. Encrypted boot (inside LVM)      - /boot is encrypted; GRUB asks for the"
    echo "                                      passphrase, then the initramfs asks again."
    echo "                                      BIOS/legacy boot only."
    echo "2. Unencrypted boot (separate part) - simpler and required for UEFI."
    echo ""
    while true; do
        local boot_choice=""
        read -r -p "Select option (1 or 2): " boot_choice
        case "$boot_choice" in
            1)
                if [[ "$FIRMWARE" == "UEFI" ]]; then
                    print_warning "This machine booted in UEFI mode."
                    print_warning "UEFI firmware cannot read an encrypted /boot -- it needs a plain FAT32 ESP."
                    print_warning "Option 1 will only work if you boot this machine in legacy/CSM mode."
                    if ! ask_yes_no "Still choose encrypted boot?" n; then
                        continue
                    fi
                fi
                BOOT_ENCRYPTED="true"
                print_info "Selected: encrypted boot (inside LVM)."
                break
                ;;
            2)
                BOOT_ENCRYPTED="false"
                print_info "Selected: unencrypted boot (separate partition)."
                break
                ;;
            *)
                print_error "Invalid choice. Enter 1 or 2."
                ;;
        esac
    done

    # GPT for UEFI, MSDOS for BIOS
    if [[ "$FIRMWARE" == "UEFI" && "$BOOT_ENCRYPTED" == "false" ]]; then
        PART_TABLE="gpt"
    else
        PART_TABLE="msdos"
    fi
    print_info "Partition table: $PART_TABLE"

    # --- Sizes ---
    echo ""
    echo "Enter partition sizes with a unit: G, M or K (e.g. 1G, 512M, 16G)."
    echo ""

    local disk_bytes disk_mib
    disk_bytes=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
    disk_mib=$(( disk_bytes / 1024 / 1024 ))
    print_info "Disk size: ${disk_mib} MiB"

    while true; do
        prompt_default BOOT_SIZE "Boot partition size" "1G"
        [[ "$BOOT_SIZE" =~ ^[0-9]+$ ]] && BOOT_SIZE="${BOOT_SIZE}G"
        BOOT_SIZE="${BOOT_SIZE^^}"
        if ! validate_size "$BOOT_SIZE"; then
            print_error "Invalid size. Use forms like 1G, 512M, 1024K."
            continue
        fi
        if (( $(size_to_mib "$BOOT_SIZE") < 260 )); then
            print_warning "Boot partitions under 260 MiB are risky (FAT32 / multiple kernels)."
            ask_yes_no "Keep $BOOT_SIZE anyway?" n || continue
        fi
        break
    done

    while true; do
        prompt_default SWAP_SIZE "Swap partition size" "8G"
        [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] && SWAP_SIZE="${SWAP_SIZE}G"
        SWAP_SIZE="${SWAP_SIZE^^}"
        if ! validate_size "$SWAP_SIZE"; then
            print_error "Invalid size. Use forms like 8G, 512M."
            continue
        fi
        local need=$(( $(size_to_mib "$BOOT_SIZE") + $(size_to_mib "$SWAP_SIZE") + 4096 ))
        if (( disk_mib > 0 && need > disk_mib )); then
            print_error "Boot + swap + at least 4 GiB for root (${need} MiB) exceeds the disk (${disk_mib} MiB)."
            continue
        fi
        break
    done
}

get_timezone() {
    print_info "Timezone selection (e.g. America/Edmonton, Europe/Berlin)"
    while true; do
        prompt_default TIMEZONE "Enter timezone" "${TIMEZONE:-}"
        if [[ -z "$TIMEZONE" ]]; then
            print_error "Timezone cannot be empty."
            continue
        fi
        if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
            print_success "Timezone will be set to $TIMEZONE"
            return 0
        fi
        if [[ -d "/usr/share/zoneinfo/$TIMEZONE" ]]; then
            print_info "'$TIMEZONE' is a region. Zones inside it:"
            ls "/usr/share/zoneinfo/$TIMEZONE" | head -40 | column -c 80 2>/dev/null \
                || ls "/usr/share/zoneinfo/$TIMEZONE" | head -40
            echo ""
            print_info "Enter the full path, e.g. $TIMEZONE/<name>"
            continue
        fi
        print_error "'$TIMEZONE' is not a valid timezone."
        local matches
        matches=$(find /usr/share/zoneinfo -type f -printf '%P\n' 2>/dev/null \
                  | grep -i -- "${TIMEZONE##*/}" | head -15)
        if [[ -n "$matches" ]]; then
            print_info "Did you mean one of these?"
            echo "$matches"
        else
            print_info "Top-level regions:"
            ls /usr/share/zoneinfo/ | grep -E '^[A-Z]' | head -20
        fi
    done
}

get_system_configuration() {
    print_header "SYSTEM CONFIGURATION"
    get_timezone

    while true; do
        prompt_default HOSTNAME_VAL "Enter hostname for this system" "${HOSTNAME_VAL:-artix}"
        validate_hostname "$HOSTNAME_VAL" && break
    done
}

confirm_configuration() {
    print_header "CONFIGURATION SUMMARY"
    echo "  Disk:              $DISK"
    echo "  Firmware:          $FIRMWARE"
    echo "  Partition table:   $PART_TABLE"
    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        echo "  Boot:              Encrypted, inside LVM ($BOOT_SIZE)"
    else
        echo "  Boot:              Unencrypted, separate partition ($BOOT_SIZE)"
    fi
    echo "  Swap:              $SWAP_SIZE"
    echo "  Root:              remaining space, BTRFS"
    echo "  Encryption:        LUKS1, serpent-xts-plain64, sha512"
    echo "  Timezone:          $TIMEZONE"
    echo "  Hostname:          $HOSTNAME_VAL"
    echo ""
    lsblk "$DISK"
    echo ""
    print_warning "This will COMPLETELY ERASE $DISK. ALL DATA WILL BE LOST."
    echo ""
    echo "1. Proceed with installation"
    echo "2. Start configuration over"
    echo "3. Quit"
    echo ""
    while true; do
        local choice=""
        read -r -p "Select (1/2/3): " choice
        case "$choice" in
            1) return 0 ;;
            2) return 1 ;;
            3) print_info "Cancelled by user."; exit 0 ;;
            *) print_error "Enter 1, 2 or 3." ;;
        esac
    done
}

#=============================================================================
# PHASE 1: DISK PREPARATION
#=============================================================================

ask_secure_erase() {
    print_header "SECURE DISK ERASE"
    echo "A secure erase overwrites the whole disk with pseudorandom data."
    echo "Recommended for security, but slow (hours on a large spinning disk)."
    echo ""
    ask_yes_no "Perform a full secure erase?" n
}

quick_erase() {
    print_info "Quick erase: clearing partition table and filesystem signatures..."
    wipefs -a "$DISK" 2>/dev/null || true
    dd bs=1M if=/dev/zero of="$DISK" count=10 status=none 2>/dev/null || true
    sync

    local disk_size end_offset
    disk_size=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
    if (( disk_size > 20*1024*1024 )); then
        end_offset=$(( (disk_size - 10*1024*1024) / 1024 / 1024 ))
        dd bs=1M if=/dev/zero of="$DISK" seek="$end_offset" count=10 status=none 2>/dev/null || true
        sync
    fi
    print_success "Quick erase completed."
    return 0
}

erase_disk() {
    print_info "Securely erasing $DISK -- this may take a very long time..."
    wipefs -a "$DISK" 2>/dev/null || true

    print_info "Pass 1: zeroing the first 100 MiB..."
    dd bs=4096 if=/dev/zero of="$DISK" oflag=direct status=progress \
        count=$((100*1024*1024/4096)) 2>/dev/null || true
    sync

    print_info "Pass 2: writing AES-CTR keystream across the whole disk..."
    local pass
    pass=$(tr -cd '[:alnum:]' < /dev/urandom | head -c128)

    # Expected to end with "No space left on device" -- that is success, not failure.
    openssl enc -aes-256-ctr -pass "pass:$pass" -nosalt </dev/zero 2>/dev/null \
        | dd bs=64K of="$DISK" oflag=direct status=progress 2>&1 \
        | grep -v "No space left on device" || true
    sync

    print_success "Secure erase completed."
    return 0
}

downgrade_parted() {
    print_header "PARTED WORKAROUND"
    echo "Some Artix ISO builds ship a parted that errors with 'unrecognised disk label'."
    echo "This step downgrades parted to 3.4-2 (needs a working network connection)."
    echo ""
    if ! ask_yes_no "Downgrade parted?" n; then
        print_info "Skipping parted downgrade."
        return 0
    fi
    if pacman -U "https://archive.artixlinux.org/packages/p/parted/parted-3.4-2-x86_64.pkg.tar.zst" --noconfirm; then
        print_success "parted downgraded."
    else
        print_warning "Could not downgrade parted. Continuing with the installed version."
    fi
    return 0
}

wait_for_partition() {
    local dev="$1" i
    for i in {1..15}; do
        [[ -b "$dev" ]] && return 0
        sleep 1
    done
    return 1
}

create_partitions() {
    print_info "Creating partitions on $DISK ($PART_TABLE)..."

    unwind_storage
    wipefs -a "$DISK" 2>/dev/null || true

    parted -s "$DISK" mklabel "$PART_TABLE" || { print_error "Failed to create $PART_TABLE label."; return 1; }

    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        # One partition holding the LUKS container
        if [[ "$PART_TABLE" == "gpt" ]]; then
            parted -s -a optimal "$DISK" mkpart "cryptlvm" 1MiB 100% || return 1
        else
            parted -s -a optimal "$DISK" mkpart primary 1MiB 100% || return 1
            parted -s "$DISK" set 1 boot on || true
        fi
        parted -s "$DISK" set 1 lvm on || true
    else
        # Plain boot partition + LUKS container
        if [[ "$PART_TABLE" == "gpt" ]]; then
            parted -s -a optimal "$DISK" mkpart "ESP" fat32 1MiB "$BOOT_SIZE" || return 1
            parted -s "$DISK" set 1 esp on || true
            parted -s -a optimal "$DISK" mkpart "cryptlvm" "$BOOT_SIZE" 100% || return 1
        else
            parted -s -a optimal "$DISK" mkpart primary fat32 1MiB "$BOOT_SIZE" || return 1
            parted -s "$DISK" set 1 boot on || true
            parted -s -a optimal "$DISK" mkpart primary "$BOOT_SIZE" 100% || return 1
        fi
        parted -s "$DISK" set 2 lvm on || true
    fi

    partprobe "$DISK" 2>/dev/null || true
    sync
    sleep 1

    if ! wait_for_partition "$(part 1)"; then
        print_error "Partition $(part 1) never appeared."
        return 1
    fi
    if [[ "$BOOT_ENCRYPTED" == "false" ]] && ! wait_for_partition "$(part 2)"; then
        print_error "Partition $(part 2) never appeared."
        return 1
    fi

    echo ""
    parted -s "$DISK" print || true
    echo ""
    print_success "Partitions created:"
    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        echo "  $(part 1)  -> LUKS container (boot inside LVM)"
    else
        echo "  $(part 1)  -> boot (plain FAT32)"
        echo "  $(part 2)  -> LUKS container"
    fi
    return 0
}

crypt_partition() {
    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then part 1; else part 2; fi
}

setup_encryption() {
    print_header "DISK ENCRYPTION"

    if ! grep -q "serp" /proc/crypto; then
        print_warning "Serpent cipher not listed in /proc/crypto."
        if modprobe serpent_generic 2>/dev/null; then
            print_info "Loaded serpent_generic module."
        else
            print_warning "Could not load serpent module. luksFormat may fail."
            if ask_yes_no "Fall back to aes-xts-plain64 instead of serpent?" y; then
                CIPHER="aes-xts-plain64"
            fi
        fi
    fi
    CIPHER="${CIPHER:-serpent-xts-plain64}"

    if ask_yes_no "Run the cryptsetup benchmark first?" n; then
        cryptsetup benchmark || print_warning "Benchmark failed; continuing."
    fi

    local target
    target="$(crypt_partition)"

    if [[ ! -b "$target" ]]; then
        print_error "Encryption target $target does not exist."
        return 1
    fi

    echo ""
    print_info "Creating LUKS1 container on $target (cipher: $CIPHER)"
    print_warning "Type YES in capitals when asked to confirm."
    print_warning "Choose a strong passphrase and remember it -- without it the system is unrecoverable."
    echo ""

    # --- luksFormat, with retries (this is the one from your screenshot) ---
    while true; do
        if cryptsetup --verbose --type luks1 --cipher "$CIPHER" --key-size 512 \
                      --hash sha512 --iter-time 10000 --use-random \
                      --verify-passphrase luksFormat "$target"; then
            print_success "LUKS container created."
            break
        fi
        echo ""
        print_error "luksFormat failed."
        print_info "Common causes: the two passphrases did not match, or the"
        print_info "confirmation was not typed as YES in capital letters."
        if ! ask_yes_no "Try again?" y; then
            return 1
        fi
        echo ""
    done

    # --- luksOpen, with retries ---
    while true; do
        echo ""
        print_info "Opening the container -- enter the passphrase you just set."
        if cryptsetup luksOpen "$target" "$LUKS_NAME"; then
            STORAGE_TOUCHED=1
            print_success "Container open at /dev/mapper/$LUKS_NAME"
            return 0
        fi
        print_error "Could not open the LUKS container (wrong passphrase?)."
        if ! ask_yes_no "Try again?" y; then
            return 1
        fi
    done
}

# lvcreate with a graceful fallback when contiguous allocation is impossible.
make_lv() {
    local name="$1" size_arg="$2"
    if lvcreate --contiguous y $size_arg "$VG_NAME" --name "$name" 2>/dev/null; then
        return 0
    fi
    print_warning "Contiguous allocation failed for $name; retrying without --contiguous."
    lvcreate $size_arg "$VG_NAME" --name "$name"
}

setup_lvm() {
    print_header "LVM SETUP"

    if vgs "$VG_NAME" &>/dev/null; then
        print_warning "Volume group '$VG_NAME' already exists (leftover from a previous run)."
        if ask_yes_no "Remove it and recreate?" y; then
            vgchange -an "$VG_NAME" &>/dev/null || true
            vgremove -f "$VG_NAME" &>/dev/null || true
            pvremove -ff -y "/dev/mapper/$LUKS_NAME" &>/dev/null || true
        else
            return 1
        fi
    fi

    pvcreate -ff -y "/dev/mapper/$LUKS_NAME" || { print_error "pvcreate failed."; return 1; }
    vgcreate "$VG_NAME" "/dev/mapper/$LUKS_NAME" || { print_error "vgcreate failed."; return 1; }

    print_info "Creating logical volumes..."
    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        make_lv volBoot "--size $BOOT_SIZE" || { print_error "Could not create volBoot ($BOOT_SIZE)."; return 1; }
    fi
    make_lv volSwap "--size $SWAP_SIZE" || { print_error "Could not create volSwap ($SWAP_SIZE)."; return 1; }
    make_lv volRoot "--extents +100%FREE" || { print_error "Could not create volRoot."; return 1; }

    echo ""
    lvs || true
    print_success "LVM setup completed."
    return 0
}

format_partitions() {
    print_header "FORMATTING"

    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        print_info "Formatting /dev/$VG_NAME/volBoot as FAT32..."
        mkfs.fat -F32 -n BOOT "/dev/$VG_NAME/volBoot" || { print_error "mkfs.fat on volBoot failed."; return 1; }
    else
        print_info "Formatting $(part 1) as FAT32..."
        mkfs.fat -F32 -n BOOT "$(part 1)" || { print_error "mkfs.fat on $(part 1) failed."; return 1; }
    fi

    print_info "Creating swap..."
    mkswap -L SWAP "/dev/$VG_NAME/volSwap" || { print_error "mkswap failed."; return 1; }

    SWAP_UUID=$(blkid -s UUID -o value "/dev/$VG_NAME/volSwap" 2>/dev/null || echo "")
    if [[ -z "$SWAP_UUID" ]]; then
        print_warning "Could not read the swap UUID; hibernation resume will be skipped."
    else
        print_info "Swap UUID: $SWAP_UUID"
    fi

    print_info "Creating BTRFS root filesystem..."
    mkfs.btrfs -f -L ROOT "/dev/$VG_NAME/volRoot" || { print_error "mkfs.btrfs failed."; return 1; }

    print_success "All filesystems created."
    return 0
}

mount_partitions() {
    print_header "MOUNTING"

    swapon "/dev/$VG_NAME/volSwap" || print_warning "swapon failed; continuing without active swap."

    mount "/dev/$VG_NAME/volRoot" /mnt || { print_error "Could not mount root."; return 1; }
    STORAGE_TOUCHED=1

    mkdir -p /mnt/boot || return 1

    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        mount "/dev/$VG_NAME/volBoot" /mnt/boot || { print_error "Could not mount boot."; return 1; }
    else
        mount "$(part 1)" /mnt/boot || { print_error "Could not mount $(part 1) on /mnt/boot."; return 1; }
    fi

    print_success "Mounted:"
    echo "  /mnt        root  (BTRFS)"
    echo "  /mnt/boot   boot  (FAT32)"
    echo "  swap        active"
    return 0
}

#=============================================================================
# PHASE 2: SYSTEM INSTALLATION
#=============================================================================

install_base_system() {
    print_header "BASE SYSTEM INSTALLATION"

    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf 2>/dev/null || true

    print_info "Installing packages with basestrap (this takes a while)..."
    if ! basestrap /mnt \
            base base-devel \
            linux linux-headers linux-firmware \
            runit elogind elogind-runit \
            grub efibootmgr \
            networkmanager networkmanager-runit \
            cryptsetup lvm2 lvm2-runit mkinitcpio \
            btrfs-progs dosfstools \
            vim nano sudo; then
        print_error "basestrap failed."
        print_info "Check your network connection and mirrors, then retry."
        print_info "Sometimes 'pacman -Sy artix-keyring archlinux-keyring' fixes signature errors."
        return 1
    fi

    print_info "Generating fstab..."
    if ! fstabgen -U /mnt > /mnt/etc/fstab; then
        print_error "fstabgen failed."
        return 1
    fi
    if [[ ! -s /mnt/etc/fstab ]]; then
        print_error "/mnt/etc/fstab is empty."
        return 1
    fi

    print_success "Base system installed and fstab generated."
    return 0
}

configure_system() {
    print_header "SYSTEM CONFIGURATION"

    print_info "Setting timezone to $TIMEZONE..."
    if artix-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime; then
        print_success "Timezone set."
    else
        print_error "Failed to set timezone."
        return 1
    fi

    print_info "Syncing hardware clock..."
    artix-chroot /mnt hwclock --systohc 2>/dev/null \
        && print_success "Hardware clock synced." \
        || print_warning "hwclock failed (harmless in a VM)."

    print_info "Configuring locale..."
    cat > /mnt/etc/locale.conf <<'LOCALE_EOF'
LANG=en_US.UTF-8
LC_COLLATE=C
LOCALE_EOF
    grep -q '^en_US.UTF-8 UTF-8' /mnt/etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /mnt/etc/locale.gen
    if ! artix-chroot /mnt locale-gen; then
        print_error "locale-gen failed."
        return 1
    fi
    print_success "Locale configured."

    print_info "Setting hostname to $HOSTNAME_VAL..."
    echo "$HOSTNAME_VAL" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<HOSTS_EOF
127.0.0.1    localhost
::1          localhost
127.0.1.1    ${HOSTNAME_VAL}.localdomain ${HOSTNAME_VAL}
HOSTS_EOF
    print_success "Hostname set."

    print_info "Configuring mkinitcpio hooks..."
    cp /mnt/etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf.backup 2>/dev/null || true

    # keyboard/keymap MUST come before encrypt, or a USB keyboard may not work
    # at the passphrase prompt. lvm2 after encrypt because LVM lives inside LUKS.
    local hooks="base udev autodetect modconf kms keyboard keymap consolefont block encrypt lvm2"
    [[ -n "$SWAP_UUID" ]] && hooks="$hooks resume"
    hooks="$hooks filesystems fsck"

    if ! sed -i "s/^HOOKS=.*/HOOKS=($hooks)/" /mnt/etc/mkinitcpio.conf; then
        print_error "Could not edit mkinitcpio.conf."
        return 1
    fi
    print_success "HOOKS=($hooks)"
    return 0
}

rebuild_initramfs() {
    print_header "INITRAMFS"
    print_info "Rebuilding initramfs (mkinitcpio -P)..."
    if artix-chroot /mnt mkinitcpio -P; then
        print_success "Initramfs rebuilt."
        return 0
    fi
    print_error "mkinitcpio failed. The system will not boot without a valid initramfs."
    return 1
}

set_grub_option() {
    local key="$1" value="$2" file="/mnt/etc/default/grub"
    sed -i -E "/^[#[:space:]]*${key}=/d" "$file"
    printf '%s=%s\n' "$key" "$value" >> "$file"
}

unset_grub_option() {
    sed -i -E "/^[#[:space:]]*$1=/d" /mnt/etc/default/grub
}

configure_bootloader() {
    print_header "BOOTLOADER CONFIGURATION"

    local crypt_part crypt_uuid root_uuid
    crypt_part="$(crypt_partition)"

    crypt_uuid=$(blkid -s UUID -o value "$crypt_part" 2>/dev/null || echo "")
    root_uuid=$(blkid -s UUID -o value "/dev/mapper/${VG_NAME}-volRoot" 2>/dev/null || echo "")

    if [[ -z "$crypt_uuid" ]]; then
        print_error "Could not read the UUID of the encrypted partition ($crypt_part)."
        return 1
    fi
    if [[ -z "$root_uuid" ]]; then
        print_error "Could not read the UUID of /dev/mapper/${VG_NAME}-volRoot."
        return 1
    fi

    print_info "LUKS partition UUID: $crypt_uuid"
    print_info "Root UUID:           $root_uuid"
    [[ -n "$SWAP_UUID" ]] && print_info "Swap UUID:           $SWAP_UUID"

    cp /mnt/etc/default/grub /mnt/etc/default/grub.backup 2>/dev/null || true

    local cmdline="cryptdevice=UUID=${crypt_uuid}:${LUKS_NAME}:allow-discards root=UUID=${root_uuid} loglevel=3 quiet"
    [[ -n "$SWAP_UUID" ]] && cmdline="${cmdline} resume=UUID=${SWAP_UUID}"
    cmdline="${cmdline} net.ifnames=0"

    set_grub_option "GRUB_CMDLINE_LINUX_DEFAULT" "\"$cmdline\""

    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        set_grub_option "GRUB_PRELOAD_MODULES" "\"part_gpt part_msdos cryptodisk luks lvm\""
        set_grub_option "GRUB_ENABLE_CRYPTODISK" "y"
    else
        set_grub_option "GRUB_PRELOAD_MODULES" "\"part_gpt part_msdos lvm\""
        unset_grub_option "GRUB_ENABLE_CRYPTODISK"
    fi
    print_success "GRUB defaults updated."

    # --- Boot mode confirmation ---
    BOOT_MODE="$FIRMWARE"
    echo ""
    print_info "Detected boot mode: $BOOT_MODE"
    if ! ask_yes_no "Is that correct?" y; then
        while true; do
            echo "1) UEFI"
            echo "2) Legacy BIOS"
            local sel=""
            read -r -p "Select boot mode (1 or 2): " sel
            case "$sel" in
                1) BOOT_MODE="UEFI"; break ;;
                2) BOOT_MODE="BIOS"; break ;;
                *) print_error "Enter 1 or 2." ;;
            esac
        done
    fi

    if [[ "$BOOT_MODE" == "UEFI" && "$BOOT_ENCRYPTED" == "true" ]]; then
        print_warning "UEFI installs need an unencrypted FAT32 ESP; /boot here is encrypted."
        print_warning "grub-install will very likely fail or produce an unbootable system."
        ask_yes_no "Attempt it anyway?" n || return 1
    fi

    # --- GRUB install, with retries ---
    while true; do
        print_info "Installing GRUB ($BOOT_MODE)..."
        local ok=1
        if [[ "$BOOT_MODE" == "UEFI" ]]; then
            artix-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot \
                --bootloader-id=artix --recheck && ok=0
        else
            artix-chroot /mnt grub-install --target=i386-pc --boot-directory=/boot \
                --recheck "$DISK" && ok=0
        fi
        if (( ok == 0 )); then
            print_success "GRUB installed."
            break
        fi
        print_error "grub-install failed."
        ask_yes_no "Retry grub-install?" y || return 1
    done

    # --- grub.cfg, with retries ---
    while true; do
        if artix-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg; then
            print_success "grub.cfg generated."
            return 0
        fi
        print_error "grub-mkconfig failed."
        ask_yes_no "Retry?" y || return 1
    done
}

configure_user_settings() {
    print_header "USER SETTINGS"

    # --- Root password (retries; mismatched passwords are normal) ---
    print_info "Setting the root password."
    while true; do
        if artix-chroot /mnt passwd root; then
            print_success "Root password set."
            break
        fi
        print_error "passwd failed (passwords probably did not match)."
        if ! ask_yes_no "Try again?" y; then
            print_warning "Root password NOT set. You will need to fix this from a live ISO."
            break
        fi
    done

    # --- Optional non-root user ---
    if ask_yes_no "Create a regular (non-root) user account?" y; then
        local username=""
        while true; do
            prompt_default username "Username" ""
            if [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                break
            fi
            print_error "Invalid username. Lowercase letters, digits, '-' and '_', starting with a letter."
        done

        if artix-chroot /mnt useradd -m -G wheel,audio,video,storage -s /bin/bash "$username"; then
            while true; do
                if artix-chroot /mnt passwd "$username"; then
                    print_success "User '$username' created."
                    break
                fi
                print_error "Setting the password for '$username' failed."
                ask_yes_no "Try again?" y || break
            done
            # Enable sudo for the wheel group
            if [[ -f /mnt/etc/sudoers ]]; then
                sed -i 's/^#\s*\(%wheel ALL=(ALL:ALL) ALL\)/\1/' /mnt/etc/sudoers
                print_info "sudo enabled for the wheel group."
            fi
        else
            print_warning "useradd failed; skipping user creation."
        fi
    fi

    # --- Services ---
    print_info "Enabling NetworkManager..."
    if [[ -L /mnt/etc/runit/runsvdir/default/NetworkManager ]]; then
        print_warning "NetworkManager is already enabled."
    elif artix-chroot /mnt ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/ 2>/dev/null; then
        print_success "NetworkManager enabled."
    else
        print_warning "Could not enable NetworkManager. Enable it after boot with:"
        echo "  ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/"
    fi

    # lvm2 service, useful for activating the VG at boot
    if [[ -d /mnt/etc/runit/sv/lvmetad && ! -L /mnt/etc/runit/runsvdir/default/lvmetad ]]; then
        artix-chroot /mnt ln -s /etc/runit/sv/lvmetad /etc/runit/runsvdir/default/ 2>/dev/null || true
    fi

    return 0
}

#=============================================================================
# FINISH
#=============================================================================

cleanup_and_finish() {
    print_header "CLEANUP"
    print_info "Unmounting..."
    umount -R /mnt 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    print_info "Deactivating LVM..."
    vgchange -an "$VG_NAME" 2>/dev/null || true
    print_info "Closing LUKS container..."
    cryptsetup luksClose "$LUKS_NAME" 2>/dev/null || true
    STORAGE_TOUCHED=0
    print_success "Cleanup completed."
}

show_installation_summary() {
    print_header "INSTALLATION COMPLETE"
    echo ""
    print_success "Artix Linux has been installed."
    echo ""
    echo "Summary:"
    echo "  Disk:        $DISK ($PART_TABLE)"
    echo "  Boot:        $([[ "$BOOT_ENCRYPTED" == "true" ]] && echo "encrypted (inside LVM)" || echo "unencrypted (separate)")"
    echo "  Boot mode:   $BOOT_MODE"
    echo "  Root:        BTRFS on LVM inside LUKS1 (${CIPHER:-serpent-xts-plain64})"
    echo "  Hostname:    $HOSTNAME_VAL"
    echo "  Timezone:    $TIMEZONE"
    echo ""
    echo "Notes:"
    if [[ "$BOOT_ENCRYPTED" == "true" ]]; then
        echo "  - You will be asked for the passphrase twice at boot (GRUB, then initramfs)."
        echo "    An embedded keyfile can remove the second prompt later if you want."
    else
        echo "  - You will be asked for the passphrase once, by the initramfs."
    fi
    echo "  - NetworkManager starts automatically."
    echo "  - Install a desktop/WM and a display manager after first boot."
    echo ""
    echo "Next steps:"
    echo "  1. Remove the installation media"
    echo "  2. Reboot"
    echo "  3. Log in and finish configuring"
    echo ""
    print_warning "Do not forget the disk encryption passphrase. There is no recovery without it."
    echo ""
}

#=============================================================================
# MAIN
#=============================================================================

main() {
    print_header "ARTIX LINUX ENCRYPTED INSTALLATION"
    print_info "LUKS1 + LVM + BTRFS, runit init."
    print_warning "The selected disk will be COMPLETELY ERASED."
    echo ""

    check_root
    check_dependencies || die "Missing dependencies."
    detect_firmware

    # --- Configuration loop: nothing destructive happens here ---
    while true; do
        get_disk_configuration
        get_system_configuration
        confirm_configuration && break
        print_info "Starting configuration over..."
        echo ""
    done

    # --- Erase ---
    if ask_secure_erase; then
        retry_step "Secure erase" erase_disk || die "Secure erase aborted."
    else
        retry_step "Quick erase" quick_erase || die "Quick erase aborted."
    fi

    downgrade_parted

    # --- Disk preparation ---
    retry_step "Partitioning"        create_partitions  || die "Partitioning aborted."
    retry_step "Encryption setup"    setup_encryption   || die "Encryption aborted."
    retry_step "LVM setup"           setup_lvm          || die "LVM setup aborted."
    retry_step "Formatting"          format_partitions  || die "Formatting aborted."
    retry_step "Mounting"            mount_partitions   || die "Mounting aborted."

    # --- Installation ---
    retry_step "Base system install" install_base_system || die "Base install aborted."
    retry_step "System configuration" configure_system   || die "System configuration aborted."
    retry_step "Initramfs build"     rebuild_initramfs   || die "Initramfs build aborted."
    retry_step "Bootloader"          configure_bootloader || die "Bootloader configuration aborted."
    retry_step "User settings"       configure_user_settings || print_warning "User settings incomplete."

    # --- Done ---
    cleanup_and_finish
    show_installation_summary

    read -r -p "Press Enter to exit..." _ || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
