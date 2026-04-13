#!/bin/sh
set -e

# Usage: ./teardown_disk.sh <device>
# Reverses prepare_disk.sh: unmounts, deactivates LVM, closes LUKS,
# and detaches the device if it is a loop device.

DISK="${1:-}"

CRYPT_NAME="cryptroot"
VG_NAME="vg0"

# ── sanity checks ─────────────────────────────────────────────────────────────

if [ -z "$DISK" ]; then
    echo "Usage: $0 <device>  (e.g. /dev/sda or /dev/loop0)" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

# ── 1. swap off ───────────────────────────────────────────────────────────────

if [ -b /dev/"$VG_NAME"/swap ]; then
    echo "==> Disabling swap ..."
    swapoff /dev/"$VG_NAME"/swap || true
fi

# ── 2. unmount filesystems ────────────────────────────────────────────────────

echo "==> Unmounting filesystems ..."
umount -R /mnt 2>/dev/null || true

# ── 3. deactivate LVM ────────────────────────────────────────────────────────

if vgdisplay "$VG_NAME" > /dev/null 2>&1; then
    echo "==> Deactivating LVM volume group $VG_NAME ..."
    vgchange -an "$VG_NAME"
fi

# ── 4. close LUKS ────────────────────────────────────────────────────────────

if [ -b /dev/mapper/"$CRYPT_NAME" ]; then
    echo "==> Closing LUKS container $CRYPT_NAME ..."
    cryptsetup close "$CRYPT_NAME"
fi

# ── 5. detach loop device (if applicable) ────────────────────────────────────

case "$DISK" in
    /dev/loop*)
        if losetup "$DISK" > /dev/null 2>&1; then
            echo "==> Detaching loop device $DISK ..."
            losetup -d "$DISK"
        fi
        ;;
esac

echo ""
echo "Done. All resources for $DISK have been released."
