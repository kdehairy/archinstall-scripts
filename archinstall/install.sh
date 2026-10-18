#!/bin/sh
set -e

# Usage: ./install.sh [desktop|server]
# Assumes prepare_disk.sh has already been run (partitions formatted and mounted at /mnt).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VARIANT="${1:-desktop}"

case "$VARIANT" in
    desktop) POST_INSTALL="post_install.sh" ;;
    server)  POST_INSTALL="post_install_server.sh" ;;
    *)
        echo "Usage: $0 [desktop|server]" >&2
        exit 1
        ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

if ! mountpoint -q /mnt; then
    echo "Error: /mnt is not mounted. Run prepare_disk.sh first." >&2
    exit 1
fi

# CPU microcode (embedded into the initramfs by the mkinitcpio "microcode" hook)
case "$(grep -m1 '^vendor_id' /proc/cpuinfo)" in
    *GenuineIntel*) UCODE="intel-ucode" ;;
    *AuthenticAMD*) UCODE="amd-ucode" ;;
    *)
        UCODE=""
        echo "Note: unknown CPU vendor — skipping microcode package."
        ;;
esac

echo "==> Installing base system ..."
# shellcheck disable=SC2086  # $UCODE is intentionally unquoted so an empty value adds no argument
pacstrap -K /mnt base linux linux-firmware lvm2 cryptsetup $UCODE

echo "==> Generating fstab ..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "==> Copying post-install script ($VARIANT) ..."
cp "$SCRIPT_DIR/$POST_INSTALL" /mnt/root/post_install.sh
chmod +x /mnt/root/post_install.sh

echo "==> Entering chroot ..."
arch-chroot /mnt /root/post_install.sh

rm /mnt/root/post_install.sh

echo ""
echo "Done. Unmount and reboot:"
echo "  umount -R /mnt && swapoff -a && reboot"
