#!/bin/sh
set -e

# Runs inside arch-chroot. Called by install.sh — do not run directly.

# Timezone
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
hwclock --systohc

# Locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us"        > /etc/vconsole.conf

# Hostname
printf "Hostname: "
read -r HOSTNAME
echo "${HOSTNAME}" > /etc/hostname

# NTP
systemctl enable systemd-timesyncd

pacman -S --noconfirm \
    iwd \
    pipewire pipewire-pulse pipewire-alsa pipewire-audio wireplumber \
    sway swaybg swaylock swayidle \
    waybar swaync \
    brightnessctl grim slurp \
    pavucontrol \
    ttf-firacode-nerd \
    otf-firamono-nerd \
    foot \
    xorg-xwayland \
    xdg-user-dirs \
    qt5-wayland qt6-wayland \
    xdg-desktop-portal-gnome \
    zsh tmux neovim \
    git base-devel rustup \
    polkit \
		pkgfile \
		zip unzip \
		npm \
		curl wget \
		luarocks \
		libusb-compat pcsclite ccid \
		less

# smartcard
systemctl enable pcscd

# Networking
systemctl enable iwd systemd-networkd systemd-resolved polkit
rm -f /etc/resolv.conf && ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

cat > /etc/systemd/network/20-wlan.network << 'EOF'
[Match]
Name=wl*

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes
MulticastDNS=yes

# systemd-networkd does not set per-interface-type default route metrics
# https://github.com/systemd/systemd/issues/17698
# Explicitly set route metric, so that Ethernet is preferred over Wi-Fi and Wi-Fi is preferred over mobile broadband.
# Use values from NetworkManager. From nm_device_get_route_metric_default in
# https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/blob/main/src/core/devices/nm-device.c
[DHCPv4]
RouteMetric=600

[IPv6AcceptRA]
RouteMetric=600
EOF

cat > /etc/systemd/network/20-ethernet.network << 'EOF'
[Match]
# Matching with "Type=ether" causes issues with containers because it also matches virtual Ethernet interfaces (veth*).
# See https://bugs.archlinux.org/task/70892
# Instead match by globbing the network interface name.
Name=en*
Name=eth*

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes
MulticastDNS=yes

# systemd-networkd does not set per-interface-type default route metrics
# https://github.com/systemd/systemd/issues/17698
# Explicitly set route metric, so that Ethernet is preferred over Wi-Fi and Wi-Fi is preferred over mobile broadband.
# Use values from NetworkManager. From nm_device_get_route_metric_default in
# https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/blob/main/src/core/devices/nm-device.c
[DHCPv4]
RouteMetric=100

[IPv6AcceptRA]
RouteMetric=100
EOF

# zram swap
pacman -S --noconfirm zram-generator
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

# initramfs (systemd hooks)
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader (systemd-boot)
bootctl install

cat > /boot/loader/loader.conf << 'EOF'
default arch.conf
timeout 3
console-mode max
editor no
EOF

CRYPT_UUID=$(blkid -s UUID -o value /dev/disk/by-partlabel/cryptroot)

cat > /boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options rd.luks.name=${CRYPT_UUID}=cryptroot root=/dev/vg0/root rw quiet
EOF

cat > /boot/loader/entries/arch-fallback.conf << EOF
title   Arch Linux (fallback initramfs)
linux   /vmlinuz-linux
initrd  /initramfs-linux-fallback.img
options rd.luks.name=${CRYPT_UUID}=cryptroot root=/dev/vg0/root rw
EOF

# Users
printf "Username: "
read -r USERNAME

useradd -m -G wheel -s /usr/bin/zsh "$USERNAME"
passwd "$USERNAME"
echo ""
printf "Root passoword"
passwd root

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Rust toolchain
su - "$USERNAME" -c "rustup default stable"

pacman -Scc --noconfirm

# paru
echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/aur_install

su - "$USERNAME" -c "git clone https://aur.archlinux.org/paru.git /tmp/paru && cd /tmp/paru && makepkg --noconfirm"
pacman -U --noconfirm /tmp/paru/paru-*.pkg.tar.zst
rm -rf /tmp/paru

# AUR packages
su - "$USERNAME" -c "paru -S --noconfirm --skipreview kickoff dotter-rs zsh-zim-git"

rm /etc/sudoers.d/aur_install

# Dotfiles
su - "$USERNAME" -c "git clone https://codeberg.org/kdehairy/dotfiles.git /home/$USERNAME/.dotfiles"
cat > "/home/${USERNAME}/.dotfiles/.dotter/local.toml" << 'EOF'
packages = ["sway", "zsh", "tmux", "foot", "nvim", "os", "kickoff", "waybar"]
EOF
chown "$USERNAME:$USERNAME" "/home/${USERNAME}/.dotfiles/.dotter/local.toml"

echo ""
echo "Post-install complete."
