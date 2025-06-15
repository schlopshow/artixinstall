# Artix Linux Complete Installation Script

A comprehensive, automated installation script for Artix Linux with full disk encryption using LUKS and LVM.

## ⚠️ WARNING

**This script will completely erase the selected disk and all data on it. Make sure you have backups of any important data before running this script.**

## Features

### Security Features
- **Full Disk Encryption** with LUKS1
- **Serpent-XTS-Plain64** cipher (512-bit key)
- **SHA512** hash algorithm
- **Secure disk erasure** option (optional but recommended)
- **LVM on LUKS** setup for flexible partition management

### Automated Installation
- **Interactive configuration** with validation
- **Base system installation** with essential packages
- **Bootloader configuration** (GRUB with UEFI/Legacy BIOS support)
- **Network configuration** (NetworkManager)
- **Timezone and locale setup**
- **Initramfs configuration** with encryption hooks

## Prerequisites

### System Requirements
- Boot from Artix Linux installation media
- Internet connection (for package downloads)
- Root access
- Target disk with sufficient space

### Recommended Minimum Disk Space
- **Boot**: 1GB
- **Swap**: Equal to or 2x your RAM
- **Root**: At least 20GB (more recommended)

## Installation Process

### 1. Download and Prepare
```bash
# Download the script (if available online)
curl -O https://example.com/artix-complete-install.sh

# Or create the script file manually and copy the content
nano artix-complete-install.sh
chmod +x artix-complete-install.sh
```

### 2. Run the Script
```bash
sudo ./artix-complete-install.sh
```

### 3. Follow Interactive Prompts

The script will guide you through:

#### Disk Configuration
- Select target disk from available devices
- Configure boot partition size (e.g., `1G`)
- Configure swap partition size (e.g., `8G`)
- Confirm configuration and disk erasure

#### Security Options
- Choose secure disk erasure (recommended for security)
- Set strong LUKS encryption passphrase

#### System Configuration (in chroot)
- Set timezone (region/city)
- Configure hostname
- Set root password
- Configure bootloader

## Script Phases

### Phase 1: Disk Encryption Setup
1. **Disk Selection**: Interactive disk selection with validation
2. **Secure Erasure**: Optional cryptographic disk wiping
3. **Partitioning**: Single partition for LVM
4. **Encryption**: LUKS1 container creation
5. **LVM Setup**: Physical volume, volume group, and logical volumes
6. **Formatting**: File system creation and mounting

### Phase 2: System Installation
1. **Base Installation**: Essential packages and kernel
2. **System Configuration**: Timezone, locale, hostname
3. **Boot Configuration**: mkinitcpio and GRUB setup
4. **User Setup**: Root password configuration
5. **Services**: NetworkManager enablement

## Configuration Details

### Encryption Specifications
- **Type**: LUKS1
- **Cipher**: serpent-xts-plain64
- **Key Size**: 512 bits
- **Hash**: SHA512
- **Iteration Time**: 10000ms
- **Random Source**: /dev/random

### LVM Layout
```
/dev/mapper/lvm-system (LUKS container)
├── lvmSystem-volBoot  → /boot (FAT32)
├── lvmSystem-volSwap  → swap
└── lvmSystem-volRoot  → / (BTRFS)
```


### Recommended Next Steps
1. **Create regular user account**:
   ```bash
   useradd -m -G wheel -s /bin/bash username
   passwd username
   ```

2. **Configure sudo**:
   ```bash
   EDITOR=vim visudo
   # Uncomment: %wheel ALL=(ALL:ALL) ALL
   ```

3. **Update system**:
   ```bash
   pacman -Syu
   ```

4. **Install desktop environment**:
   ```bash
   # Example for XFCE
   pacman -S xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
   ln -s /etc/runit/sv/lightdm /etc/runit/runsvdir/default/
   ```

5. **Configure firewall**:
   ```bash
   pacman -S ufw
   ufw enable
   ```

## Troubleshooting

### Common Issues

#### Boot Issues
- **Forgot LUKS passphrase**: Unfortunately, data is unrecoverable
- **GRUB not found**: Check if boot partition is properly mounted
- **Kernel panic**: Verify initramfs hooks include `encrypt` and `lvm2`

#### Encryption Issues
- **Slow boot**: Normal for encrypted systems, especially on first boot
- **Multiple password prompts**: Check GRUB configuration for correct UUIDs

#### Network Issues
- **No internet**: NetworkManager should start automatically
- **Check service**: `sv status NetworkManager`

### Recovery Mode
If the system fails to boot:
1. Boot from installation media
2. Open LUKS container:
   ```bash
   cryptsetup luksOpen /dev/sdX1 lvm-system
   ```
3. Mount filesystems:
   ```bash
   mount /dev/lvmSystem/volRoot /mnt
   mount /dev/lvmSystem/volBoot /mnt/boot
   ```
4. Chroot and fix issues:
   ```bash
   artix-chroot /mnt
   ```

### Manual Cleanup (if needed)
```bash
umount -R /mnt
swapoff -a
vgchange -an lvmSystem
cryptsetup luksClose lvm-system
sync
```

## Security Considerations

### Strengths
- Strong encryption (Serpent cipher, 512-bit key)
- Secure random number generation
- Optional secure disk erasure
- Encrypted swap partition

### Limitations
- LUKS1 (older version, but widely supported)
- Single point of failure (forgotten passphrase)
- Cold boot attacks (physical access)

### Best Practices
- Use a strong, memorable passphrase
- Consider key file backup on separate media
- Regular system updates
- Physical security of the device

## License

This script is provided as-is for educational and personal use. Use at your own risk.

## Contributing

Feel free to submit issues, suggestions, or improvements. Always test changes in a virtual machine first.

## Disclaimer

This script performs destructive operations on disk drives. The authors are not responsible for any data loss or system damage. Always backup important data and test in a virtual environment first.




## To Do List
I need to add the ability to choose which init system your using, I also want to have the same interactive installtion that for example debian has.


## Why?
I made this script to make my life slightly easier because I like using artix, using a rolling release distro without understanding how to fix things is a mistake.
