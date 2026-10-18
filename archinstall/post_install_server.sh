#!/bin/sh
set -e

# Runs inside arch-chroot. Called by install.sh server — do not run directly.
# Headless server: sshd, networking, shell environment and dotfiles; no desktop.

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
    openssh \
    zsh tmux neovim \
    git base-devel rustup \
    curl \
    less

# Networking
systemctl enable iwd systemd-networkd systemd-resolved
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
echo "Root password:"
passwd root

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel

# SSH
# The authorized key is derived from the authentication ([A]) subkey of a published
# OpenPGP key, fetched into a throwaway keyring so root on the new system gets no ~/.gnupg.
PASSWORD_AUTH=yes
GNUPGHOME=$(mktemp -d)
export GNUPGHOME

while :; do
    printf "Email of the OpenPGP key to authorize for SSH (leave empty to keep password login): "
    read -r GPG_EMAIL
    [ -z "$GPG_EMAIL" ] && break

    if ! gpg --auto-key-locate clear,wkd,keyserver --keyserver hkps://keys.openpgp.org \
            --locate-external-keys "$GPG_EMAIL"; then
        echo "No key found for $GPG_EMAIL (tried WKD and keys.openpgp.org)."
        continue
    fi

    FPRS=$(gpg --with-colons --list-keys "<${GPG_EMAIL}>" \
        | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }')
    if [ "$(echo "$FPRS" | wc -l)" -ne 1 ]; then
        echo "More than one key matches $GPG_EMAIL:"
        echo "$FPRS"
        echo "Remove the stale keys from WKD/keyserver or use a different address."
        continue
    fi
    FPR="$FPRS"

    echo ""
    gpg --fingerprint --with-subkey-fingerprints "$FPR"
    printf "Is this your key? Authorize it for SSH login as %s [y/N]: " "$USERNAME"
    read -r confirm
    case "$confirm" in
        [yY]|[yY][eE][sS]) ;;
        *) continue ;;
    esac

    if ! SSH_KEY=$(gpg --export-ssh-key "$FPR"); then
        echo "Key $FPR has no authentication subkey usable for SSH."
        continue
    fi

    install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/${USERNAME}/.ssh"
    printf '%s\n' "$SSH_KEY" > "/home/${USERNAME}/.ssh/authorized_keys"
    chmod 600 "/home/${USERNAME}/.ssh/authorized_keys"
    chown "$USERNAME:$USERNAME" "/home/${USERNAME}/.ssh/authorized_keys"
    echo "Authorized: $SSH_KEY"
    PASSWORD_AUTH=no
    break
done

gpgconf --kill all
rm -rf "$GNUPGHOME"
unset GNUPGHOME

cat > /etc/ssh/sshd_config.d/10-server.conf << EOF
PermitRootLogin no
PasswordAuthentication ${PASSWORD_AUTH}
KbdInteractiveAuthentication no
EOF

systemctl enable sshd

# Rust toolchain
su - "$USERNAME" -c "rustup default stable"

pacman -Scc --noconfirm

# paru
# sudoers.d is parsed in lexical order and the last match wins, so this must sort after 10-wheel
echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/90-aur_install

su - "$USERNAME" -c "git clone https://aur.archlinux.org/paru.git /tmp/paru && cd /tmp/paru && makepkg --noconfirm"
pacman -U --noconfirm /tmp/paru/paru-*.pkg.tar.zst
rm -rf /tmp/paru

# AUR packages
su - "$USERNAME" -c "paru -S --noconfirm --skipreview dotter-rs zsh-zim-git"

rm /etc/sudoers.d/90-aur_install

# Dotfiles
su - "$USERNAME" -c "git clone https://codeberg.org/kdehairy/dotfiles.git /home/$USERNAME/.dotfiles"
cat > "/home/${USERNAME}/.dotfiles/.dotter/local.toml" << 'EOF'
packages = ["zsh", "tmux", "nvim", "os", "git"]
EOF
chown "$USERNAME:$USERNAME" "/home/${USERNAME}/.dotfiles/.dotter/local.toml"

echo ""
echo "Post-install complete."
