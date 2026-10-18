#!/bin/sh
set -e

# Runs inside arch-chroot. Called by install.sh server — do not run directly.
# Headless server: sshd, networking, shell environment and dotfiles; no desktop.
# Safe to re-run: every step checks or overwrites existing state.

# Never leave the temporary NOPASSWD pacman rule or the throwaway keyring behind, even if a step fails
cleanup() {
    rm -f /etc/sudoers.d/90-aur_install
    if [ -n "${GPG_TMP:-}" ]; then
        GNUPGHOME="$GPG_TMP" gpgconf --kill all 2>/dev/null || true
        rm -rf "$GPG_TMP"
    fi
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

# SSH
# The authorized key is derived from the authentication ([A]) subkey of a published
# OpenPGP key, fetched into a throwaway keyring so root on the new system gets no ~/.gnupg.
AUTH_KEYS="/home/${USERNAME}/.ssh/authorized_keys"
ASK_KEY=1

if [ -s "$AUTH_KEYS" ]; then
    echo ""
    echo "Already authorized for $USERNAME:"
    ssh-keygen -lf "$AUTH_KEYS" || true
    printf "Authorize another OpenPGP key? [y/N]: "
    read -r another
    case "$another" in
        [yY]|[yY][eE][sS]) ;;
        *) ASK_KEY=0 ;;
    esac
fi

if [ "$ASK_KEY" -eq 1 ]; then
    GPG_TMP=$(mktemp -d)
    export GNUPGHOME="$GPG_TMP"
fi

while [ "$ASK_KEY" -eq 1 ]; do
    printf "Email of the OpenPGP key to authorize for SSH (leave empty to skip): "
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
    if grep -qxF "$SSH_KEY" "$AUTH_KEYS" 2>/dev/null; then
        echo "Already authorized: $SSH_KEY"
    else
        printf '%s\n' "$SSH_KEY" >> "$AUTH_KEYS"
        echo "Authorized: $SSH_KEY"
    fi
    chmod 600 "$AUTH_KEYS"
    chown "$USERNAME:$USERNAME" "$AUTH_KEYS"
    break
done

if [ -n "${GPG_TMP:-}" ]; then
    gpgconf --kill all
    rm -rf "$GPG_TMP"
    unset GNUPGHOME GPG_TMP
fi

# Password login over SSH stays enabled only while no key is authorized
if [ -s "$AUTH_KEYS" ]; then
    PASSWORD_AUTH=no
else
    PASSWORD_AUTH=yes
fi

cat > /etc/ssh/sshd_config.d/10-server.conf << EOF
PermitRootLogin no
PasswordAuthentication ${PASSWORD_AUTH}
KbdInteractiveAuthentication no
EOF

systemctl enable sshd

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
su - "$USERNAME" -c "paru -S --needed --noconfirm --skipreview dotter-rs zsh-zim-git"

rm -f /etc/sudoers.d/90-aur_install

# Dotfiles (an existing checkout is left untouched)
if [ ! -d "/home/${USERNAME}/.dotfiles" ]; then
    su - "$USERNAME" -c "git clone https://codeberg.org/kdehairy/dotfiles.git /home/$USERNAME/.dotfiles"
fi
cat > "/home/${USERNAME}/.dotfiles/.dotter/local.toml" << 'EOF'
packages = ["zsh", "tmux", "nvim", "os", "git"]
EOF
chown "$USERNAME:$USERNAME" "/home/${USERNAME}/.dotfiles/.dotter/local.toml"

echo ""
echo "Post-install complete."
