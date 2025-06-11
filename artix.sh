# cfdisk create two partitions one for boot and one for LVM


# Make a logical volume for root, boot and swap file systems

# make the root logical volume into btrfs

# make swap into SWAP

# Make the boot file system into fat32

# ensure that the drive is MSDOS based and not gpt

# mount all the file systems to the correct location, root to /mnt/, home to /mnt/home, boot to /mnt/boot

# basetrap all the neccesary packages
# base base-devel grub networkmanager networkmanager-runit elogind-runit vim efibootmgr (if efi) cryptsetup lvm2 linux linux-firmware linux-headers

fstabgen /mnt > /mnt/etc/fstab

artix-chroot /mnt

# add some information about our locale and lanaguage
# setup systemclock / time and date
# setup /etc/hosts
# setup runit init systems like networkmanager, modem manager

# edit /etc/mkinitcpio using a sed command
mkininitcpio -P

# Edit /etc/default/grub and add luks
# use blkid to get the id of /dev/sda etc. and the put it in the correct place in the file using sed command.


# grub install (depends on whether efi or legacy boot)



# setup sudo user
# setup root password

# reboot
