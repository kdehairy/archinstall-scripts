#!/bin/sh

set -e

# Usage: ./qemu_test.sh <arch-iso> [image] [size]
# Example: ./qemu_test.sh ~/Downloads/archlinux-x86_64.iso
#          ./qemu_test.sh ~/Downloads/archlinux-x86_64.iso arch-test.qcow2 60G

ISO="${1:-}"
IMAGE="${2:-target/arch-test.qcow2}"
SIZE="${3:-60G}"
RESOLUTION="${4:-1920x1080}"


if [ -z "$ISO" ]; then
    echo "Usage: $0 <arch-iso> [image] [size]" >&2
    exit 1
fi

if [ ! -f "$ISO" ]; then
    echo "Error: ISO not found: $ISO" >&2
    exit 1
fi

for cmd in qemu-system-x86_64 qemu-img; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        echo "Error: $cmd not found." >&2
        exit 1
    fi
done

# EFI firmware

OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS_SRC="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
OVMF_VARS="./target/OVMF_VARS.fd"

if [ -f "$OVMF_CODE" ]; then
    USE_EFI=1
    if [ ! -f "$OVMF_VARS" ]; then
        mkdir -p target
        cp "$OVMF_VARS_SRC" "$OVMF_VARS"
    fi
else
    USE_EFI=0
    echo "Note: OVMF firmware not found — running in legacy BIOS mode."
    echo "      For EFI support: pacman -S edk2-ovmf"
    echo ""
fi

# Disk image

if [ ! -f "$IMAGE" ]; then
    echo "==> Creating $IMAGE ($SIZE) ..."
    mkdir -p target
    qemu-img create -f qcow2 "$IMAGE" "$SIZE"
else
    echo "==> Using existing image $IMAGE ($(qemu-img info --output=human "$IMAGE" | grep "virtual size" | awk '{print $3, $4}'))"
fi

XRES="${RESOLUTION%x*}"
YRES="${RESOLUTION#*x}"

echo "==> Launching QEMU ..."
echo "    ISO:        $ISO"
echo "    Image:      $IMAGE"
echo "    EFI:        $([ "$USE_EFI" -eq 1 ] && echo "yes (OVMF)" || echo "no (legacy BIOS)")"
echo "    Resolution: ${XRES}x${YRES}"
echo "    SSH:        ssh -p 2222 root@localhost"
echo ""

if [ "$USE_EFI" -eq 1 ]; then
    exec qemu-system-x86_64 \
        -enable-kvm \
        -m 8G \
        -smp 4 \
        -cpu host \
        -vga none -device "virtio-vga,xres=${XRES},yres=${YRES}" \
        -display gtk,zoom-to-fit=off \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -cdrom "$ISO" \
        -drive file="$IMAGE",format=qcow2 \
        -boot order=d \
        -net nic -net user,hostfwd=tcp::2222-:22
else
    exec qemu-system-x86_64 \
        -enable-kvm \
        -m 8G \
        -smp 4 \
        -cpu host \
        -vga virtio \
        -display gtk,zoom-to-fit=off \
        -cdrom "$ISO" \
        -drive file="$IMAGE",format=qcow2 \
        -boot order=d \
        -net nic -net user,hostfwd=tcp::2222-:22
fi
