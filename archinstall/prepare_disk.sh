#!/bin/sh
set -e

# Usage: ./prepare_disk.sh <device>
# Example: ./prepare_disk.sh /dev/sda
#
# Layout:
#   Part 1 - EFI System   <EFI_SIZE>   FAT32
#   Part 2 - Linux LUKS   rest         LUKS2 -> LVM
#              vg0/swap   <SWAP_SIZE>  swap  (optional)
#              vg0/root   50 GB        ext4
#              vg0/home   rest         ext4

DISK="${1:-}"

if ! command -v sgdisk > /dev/null 2>&1; then
    echo "==> sgdisk not found, installing gptfdisk via pacman ..."
    pacman -Sy --noconfirm gptfdisk
fi

if [ -z "$DISK" ]; then
    echo "Usage: $0 <device>  (e.g. /dev/sda or /dev/nvme0n1)" >&2
    exit 1
fi

if [ ! -b "$DISK" ]; then
    echo "Error: $DISK is not a block device." >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

# Append 'G' if the value has no unit suffix (sgdisk treats bare numbers as sectors)
ensure_unit() {
    case "$1" in
        *[KkMmGgTtPp]) echo "$1" ;;
        *) echo "${1}G" ;;
    esac
}

printf "EFI partition size [512M]: "
read -r EFI_SIZE
EFI_SIZE=$(ensure_unit "${EFI_SIZE:-512M}")

printf "Root volume size [50G]: "
read -r ROOT_SIZE
ROOT_SIZE=$(ensure_unit "${ROOT_SIZE:-25G}")

printf "Create a swap volume? [y/N]: "
read -r want_swap
case "$want_swap" in
    [yY]|[yY][eE][sS])
        USE_SWAP=1
        printf "Swap size [8G]: "
        read -r SWAP_SIZE
        SWAP_SIZE=$(ensure_unit "${SWAP_SIZE:-8G}")
        ;;
    *)
        USE_SWAP=0
        SWAP_SIZE=0
        ;;
esac

case "$DISK" in
    *nvme*|*mmcblk*|*loop*) PART="${DISK}p" ;;
    *)                      PART="${DISK}"  ;;
esac

EFI_PART="${PART}1"
CRYPT_PART="${PART}2"

CRYPT_NAME="cryptroot"
VG_NAME="vg0"


echo ""
echo "Target layout for $DISK:"
printf "%-20s  %8s  %-10s  %s\n" "NAME" "SIZE" "TYPE" "FSTYPE"
printf "%-20s  %8s  %-10s  %s\n" "${DISK##*/}"              ""           "disk"  ""
printf "%-20s  %8s  %-10s  %s\n" "├─${EFI_PART##*/}"        "$EFI_SIZE"  "part"  "vfat"
printf "%-20s  %8s  %-10s  %s\n" "└─${CRYPT_PART##*/}"      "rest"       "part"  "crypto_LUKS"
printf "%-20s  %8s  %-10s  %s\n" "  └─$CRYPT_NAME"          ""           "crypt" ""
if [ "$USE_SWAP" -eq 1 ]; then
    printf "%-20s  %8s  %-10s  %s\n" "    ├─${VG_NAME}-swap" "$SWAP_SIZE" "lvm"   "swap"
fi
printf "%-20s  %8s  %-10s  %s\n" "    ├─${VG_NAME}-root"    "$ROOT_SIZE" "lvm"   "ext4"
printf "%-20s  %8s  %-10s  %s\n" "    └─${VG_NAME}-home"    "rest"       "lvm"   "ext4"
echo ""


echo "WARNING: All data on $DISK will be destroyed."
printf "Type YES to continue: "
read -r confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

echo "==> Partitioning $DISK ..."

sgdisk --zap-all "$DISK"

sgdisk \
    --new=1:0:"+${EFI_SIZE}"  --typecode=1:ef00 --change-name=1:"EFI" \
    --new=2:0:0               --typecode=2:8309 --change-name=2:"cryptroot" \
    "$DISK"

# Inform the kernel of the new partition table
partprobe "$DISK"
sleep 1

# EFI
echo "==> Formatting EFI partition ($EFI_PART) ..."
mkfs.fat -F32 -n EFI "$EFI_PART"

# LUKS
echo "==> Setting up LUKS2 on $CRYPT_PART ..."
cryptsetup luksFormat --type luks2 --label cryptroot "$CRYPT_PART"

echo "==> Opening LUKS container as /dev/mapper/$CRYPT_NAME ..."
cryptsetup open "$CRYPT_PART" "$CRYPT_NAME"

# LVM on LUKS
echo "==> Creating LVM structure inside LUKS ..."
pvcreate /dev/mapper/"$CRYPT_NAME"
vgcreate "$VG_NAME" /dev/mapper/"$CRYPT_NAME"

if [ "$USE_SWAP" -eq 1 ]; then
    lvcreate -L "$SWAP_SIZE" -n swap "$VG_NAME"
fi
lvcreate -L "$ROOT_SIZE" -n root "$VG_NAME"
lvcreate -l 100%FREE -n home "$VG_NAME"

echo "==> Formatting logical volumes ..."
if [ "$USE_SWAP" -eq 1 ]; then
    mkswap -L swap /dev/"$VG_NAME"/swap
fi
mkfs.ext4 -L root /dev/"$VG_NAME"/root
mkfs.ext4 -L home /dev/"$VG_NAME"/home

# mount it for archinstall
echo "==> Mounting filesystems ..."
mount /dev/"$VG_NAME"/root /mnt
mkdir -p /mnt/boot /mnt/home
mount "$EFI_PART" /mnt/boot
mount /dev/"$VG_NAME"/home /mnt/home
if [ "$USE_SWAP" -eq 1 ]; then
    swapon /dev/"$VG_NAME"/swap
fi

echo ""
echo "Done. Disk layout:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK"
