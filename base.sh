#!/usr/bin/zsh

# This is an arch linux installation script, intended to do my system installation.
# You can use it yourself, but you'll probably have to customize it a bit.

CYAN='%F{cyan}'
NC='%f' # No Color

set -e

# Set keyboard map to swiss german
print -P "${CYAN}Setting keyboard layout...${NC}"
loadkeys de_CH-latin1

# Update system clock
print -P "${CYAN}Updating system clock...${NC}"
timedatectl set-ntp true

# Partition the disk
print -P "${CYAN}Partitioning the disks...${NC}"
sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk /dev/nvme0n1
  g # make a gpt table
  n #### new partition
  p # primary partition
  1 # partition number 1
    # default - start at beginning of disk 
  +8G # Boot/EFI partition
  n #### new partition
  p # primary partition
  2 # partition number 2
    # default - start after Boot partition
    # default - fill all free space
  p # print the in-memory partition table
  w # write the partition table
  q # and we're done
EOF

# Format the EFI/Boot partition
mkfs.fat -F 32 /dev/nvme0n1p1

# Install ZFS utils
print -P "${CYAN}Installing ZFS utils...${NC}"
curl -s https://eoli3n.github.io/archzfs/init | bash

# Clear previous zfs pools
rm -rf /etc/zfs/zpool.d
mkfs.ext4 /dev/nvme0n1p2

# Make a ZFS pool
print -P "${CYAN}Setting up ZFS pool...${NC}"
zpool create -f -o ashift=9               \
                -O acltype=posixacl       \
                -O relatime=on            \
                -O xattr=sa               \
                -O dnodesize=legacy       \
                -O normalization=formD    \
                -O mountpoint=none        \
                -O canmount=off           \
                -O devices=off            \
                -R /mnt                   \
                zroot /dev/disk/by-id/nvme-SAMSUNG*-part2

# Create ZFS datasets
zfs create -o mountpoint=none        \
           -o compression=lz4        \
           -o encryption=aes-256-gcm \
           -o keyformat=passphrase   \
           -o keylocation=prompt     \
           zroot/data
zfs create -o mountpoint=/ -o canmount=noauto zroot/data/ROOT
zfs create -o mountpoint=/home zroot/data/home

# Validate ZFS config
zpool export zroot
zpool import -d /dev/disk/by-id -R /mnt zroot -N

# Load key
zfs load-key -r zroot/data

# Make root locatable
zpool set bootfs=zroot/data/ROOT zroot

# Remove dir kindly but unnesserarily created by zfs-util
rmdir /mnt/home || true

# Mount partitions
zfs mount zroot/data/ROOT
zfs mount -a
mkdir /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot

# Install essential packages
print -P "${CYAN}Installing base packages...${NC}"
pacstrap /mnt base linux linux-firmware vim grub efibootmgr zsh

print -P "${CYAN}Configuring system...${NC}"

# Copy cache
zpool set cachefile=/etc/zfs/zpool.cache zroot
mkdir /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# Generate /etc/fstab
genfstab -U -p /mnt >> /mnt/etc/fstab

# Configure system
ln -sf /mnt/usr/share/zoneinfo/Europe/Zurich /mnt/etc/localtime
arch-chroot /mnt hwclock --systohc
echo "KEYMAP=de_CH-latin1" > /mnt/etc/vconsole.conf

# Configure locale
sed -i '/en_US.UTF-8 UTF-8/s/^#//g' /mnt/etc/locale.gen
sed -i '/de_CH.UTF-8 UTF-8/s/^#//g' /mnt/etc/locale.gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
arch-chroot /mnt locale-gen

# Network configuration
echo -n "Hostname: "; read hostname
echo $hostname > /mnt/etc/hostname
cat > /mnt/etc/hosts << EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$hostname.localdomain	$hostname
EOF

# Add ZFS repos to pacman
cat >> /mnt/etc/pacman.conf << 'EOF'
[archzfs]
# Origin Server - France
Server = http://archzfs.com/$repo/x86_64
# Mirror - Germany
Server = http://mirror.sum7.eu/archlinux/archzfs/$repo/x86_64
# Mirror - Germany
Server = https://mirror.biocrafting.net/archlinux/archzfs/$repo/x86_64
# Mirror - India
Server = https://mirror.in.themindsmaze.com/archzfs/$repo/x86_64

[archzfs-kernels]
Server = http://end.re/$repo/
EOF

# Chroot
arch-chroot /mnt pacman -Sy --noconfirm zfs-linux

# Edit mkinitcpio hooks
hooks='HOOKS=(base udev autodetect keyboard keymap consolefont modconf block zfs filesystems fsck)'
sed -i "/HOOKS=/c$hooks" /mnt/etc/mkinitcpio.conf

# Regenerate initramfs
arch-chroot /mnt mkinitcpio -P

# Bind system directories
mount --rbind /sys /mnt/sys
mount --rbind /proc /mnt/proc
mount --rbind /dev /mnt/dev

# Install grub (for EFI)
print -P "${CYAN}Installing GRUB...${NC}"
chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck

# Configure grub
kernel_params="GRUB_CMDLINE_LINUX=\"root=ZFS=zroot/data/ROOT\""
sed -i "/GRUB_CMDLINE_LINUX/c$kernel_params" /mnt/etc/default/grub
ZPOOL_VDEV_NAME_PATH=1 
mkdir /mnt/boot/grub
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Set root password
print -P "${CYAN}Setting up users...${NC}"
echo "Root password:"
chroot /mnt passwd

# Add other user
echo "> New user"
echo -n "Name: "; read name
useradd -G wheel -s /usr/bin/zsh -d /home/$name $name
passwd $name

# Finish message
print -P "${CYAN}DONE!${NC}"
echo -n "Do you want to continue with the GUI? [Y/n]"; read continue
if [[ -z "$continue" || "$continue" == "Y" || "$continue" == "y" ]]; then
  chmod +x gui.sh
  chroot /mnt gui.sh $name
fi

# Unmount stuff
print -P "${CYAN}Unmounting system...${NC}"
umount /mnt/efi
umount -R /mnt/sys
umount -R /mnt/proc
umount -R /mnt/dev
zfs umount -a
zpool export zroot
umount -R /mnt
