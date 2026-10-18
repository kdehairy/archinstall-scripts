#!/bin/sh
set -e

# Runs inside arch-chroot. Called by install.sh — do not run directly.
# Safe to re-run: every step checks or overwrites existing state.

# Never leave the temporary NOPASSWD pacman rule behind, even if a step fails
cleanup() {
    rm -f /etc/sudoers.d/90-aur_install
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# Timezone
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
hwclock --systohc

# Locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us"        > /etc/vconsole.conf

# Hostname
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || true)
HOSTNAME=""
while [ -z "$HOSTNAME" ]; do
    printf "Hostname%s: " "${CURRENT_HOSTNAME:+ [$CURRENT_HOSTNAME]}"
    read -r HOSTNAME
    HOSTNAME="${HOSTNAME:-$CURRENT_HOSTNAME}"
done
echo "${HOSTNAME}" > /etc/hostname

# NTP
systemctl enable systemd-timesyncd

pacman -S --needed --noconfirm \
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
pacman -S --needed --noconfirm zram-generator
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

# initramfs (systemd hooks)
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader (systemd-boot)
if bootctl is-installed > /dev/null 2>&1; then
    bootctl --graceful update
else
    bootctl install
fi

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

if id "$USERNAME" > /dev/null 2>&1; then
    usermod -aG wheel -s /usr/bin/zsh "$USERNAME"
else
    useradd -m -G wheel -s /usr/bin/zsh "$USERNAME"
fi

# Only prompt for passwords that are not set yet ("P" = usable password)
for account in "$USERNAME" root; do
    if [ "$(passwd -S "$account" | cut -d' ' -f2)" != "P" ]; then
        echo ""
        echo "Password for $account:"
        passwd "$account"
    fi
done

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel

# Rust toolchain (an interrupted download leaves a toolchain dir without a manifest; reinstall it)
su - "$USERNAME" -c '
    if ! rustup run stable rustc --version > /dev/null 2>&1; then
        rustup toolchain uninstall stable 2> /dev/null || rm -rf ~/.rustup/toolchains/stable-* ~/.rustup/update-hashes/stable-*
        rustup toolchain install stable
    fi
    rustup default stable
'

pacman -Scc --noconfirm

# paru
# sudoers.d is parsed in lexical order and the last match wins, so this must sort after 10-wheel
echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/90-aur_install

if ! command -v paru > /dev/null 2>&1; then
    rm -rf /tmp/paru
    su - "$USERNAME" -c "git clone https://aur.archlinux.org/paru.git /tmp/paru && cd /tmp/paru && makepkg --noconfirm"
    pacman -U --noconfirm /tmp/paru/paru-*.pkg.tar.zst
    rm -rf /tmp/paru
fi

# AUR packages
su - "$USERNAME" -c "paru -S --needed --noconfirm --skipreview kickoff dotter-rs zsh-zim-git"

rm -f /etc/sudoers.d/90-aur_install

# Dotfiles (an existing checkout is left untouched)
if [ ! -d "/home/${USERNAME}/.dotfiles" ]; then
    su - "$USERNAME" -c "git clone https://codeberg.org/kdehairy/dotfiles.git /home/$USERNAME/.dotfiles"
fi
cat > "/home/${USERNAME}/.dotfiles/.dotter/local.toml" << 'EOF'
packages = ["sway", "zsh", "tmux", "foot", "nvim", "os", "kickoff", "waybar"]
EOF
chown "$USERNAME:$USERNAME" "/home/${USERNAME}/.dotfiles/.dotter/local.toml"

echo ""
echo "Post-install complete."
