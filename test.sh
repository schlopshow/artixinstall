# backslashes in this file are newlines

basestrap /mnt base base-devel linux linux-headers grub efibootmgr networkmanager networkmanager-runit elogind-runit elogind cryptsetup lvm2 mkinitcpio vim glibc grub

fstabgen -U /mnt > /mnt/etc/fstab

# chroot
 artix-chroot /mnt

# Ask user to input name of Region and City
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime

# syncs hardware clock with system clock
hwclock --systohc

echo 'LANG=en_US.UTF-8 \ export LC_COLLATE="C"' > /etc/locale.conf

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen


# ask user for hostname
echo $HOSTNAME > /etc/hostname

echo "127.0.0.1 localhost \ ::1 localhost \ 127.0.1.1 $HOSTNAME.localdomain $HOSTNAME

# hostname="virt"
#  mkinitcpio.conf
echo "base udev autodetect modconf block encrypt keyboard keymap consolefont lvm2 filesystems fsck" > /etc/mkinitcpio.conf # I want this command to become a sed or something that simple replaces the origninal line with this line instead.

 mkinitcpio -P




# I want this to be sed into /etc/default/grub in the correct line. I simply want the line replaced with this instead of anything else. You can probably use awk to do this as well, don't hardcode line numbers etc.
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$(blkid -s UUID -o value ${DISK}1):lvm-system:allow-discards UUID=$(blkid -s UUID -o value /dev/mapper/lvmSystem-volRoot):root loglevel=3 quiet resume=UUID=$(blkid -s UUID -o /dev/mapper/lvmSystem-volSwap) net.ifnames=0\""

# there needs to be an option here to allow for EFI installations, ask user if their system is UEFI or Legacy
# this is the legacy boot grub install
 grub-install --target=i386-pc --boot-directory=/boot --bootloader-id=artix --recheck /dev/$DISK

# This is for uefi
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=artix   # for UEFI systems

#Do this after the grub install
grub-mkconfig -o /boot/grub/grub.cfg
