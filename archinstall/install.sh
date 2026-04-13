#!/bin/sh
set -e

# Usage: ./install.sh
# Assumes prepare_disk.sh has already been run (partitions formatted and mounted at /mnt).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

if ! mountpoint -q /mnt; then
    echo "Error: /mnt is not mounted. Run prepare_disk.sh first." >&2
    exit 1
fi

echo "==> Installing base system ..."
pacstrap -K /mnt base linux linux-firmware lvm2 cryptsetup

echo "==> Generating fstab ..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "==> Copying post-install script ..."
cp "$SCRIPT_DIR/post_install.sh" /mnt/root/post_install.sh
chmod +x /mnt/root/post_install.sh

echo "==> Entering chroot ..."
arch-chroot /mnt /root/post_install.sh

rm /mnt/root/post_install.sh

echo ""
echo "Done. Unmount and reboot:"
echo "  umount -R /mnt && swapoff -a && reboot"
