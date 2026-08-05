# utils

Scripts for automating an Arch Linux install: LUKS2-on-LVM disk setup, base system
bootstrap, and personal post-install configuration (Sway/Wayland desktop, dotfiles,
AUR packages).

## Layout

```
archinstall/
- prepare_disk.sh   partition, encrypt, format, and mount the target disk
- install.sh        pacstrap the base system and hand off to post_install.sh
- post_install.sh   runs inside the chroot; only invoked by install.sh
- teardown_disk.sh  reverse prepare_disk.sh (unmount, close LUKS, deactivate LVM)
- qemu_test.sh      boot the Arch ISO in QEMU/KVM to test the scripts end-to-end
```

## Disk layout

`prepare_disk.sh` creates:

```
<disk>
- EFI partition (FAT32, default 512M)
- LUKS2 partition ("cryptroot")
   - LVM volume group "vg0"
     - swap  (optional, default 8G)
     - root  (default 50G, ext4)
     - home  (remaining space, ext4)
```

## Usage

Run from the Arch ISO live environment, as root, against the machine you intend to
wipe.

1. Partition, encrypt, and mount the target disk
```sh
./archinstall/prepare_disk.sh /dev/nvme0n1
```

2. Install the base system, then run post-install setup in the chroot
```sh
./archinstall/install.sh
```

3. Reboot into the new system
```sh
umount -R /mnt && swapoff -a && reboot
```

`install.sh` copies `post_install.sh` into `/mnt/root/` and runs it via
`arch-chroot`; it prompts interactively for hostname, username, and passwords.
`post_install.sh` is not meant to be run directly.

To undo `prepare_disk.sh` without rebooting (e.g. between test iterations):

```sh
./archinstall/teardown_disk.sh /dev/nvme0n1
```

## Testing in QEMU

Validate changes against a throwaway VM instead of real hardware:

```sh
./archinstall/qemu_test.sh /path/to/archlinux-x86_64.iso
```

This creates a qcow2 disk image and OVMF vars under `target/` (gitignored), boots
the ISO with the disk attached, and forwards guest SSH to `localhost:2222`. Inside
the VM, run `prepare_disk.sh` / `install.sh` against the virtual disk (typically
`/dev/vda`), then `teardown_disk.sh /dev/vda` to reset disk state between runs.

Optional arguments: `./qemu_test.sh <arch-iso> [image] [size] [resolution]`.

**Warning:** these scripts are destructive by design (`sgdisk --zap-all`, `mkfs`,
`pacman -S`, user creation). Only run them against a QEMU test image or a real disk
you intend to erase.
