#!/usr/bin/env bash

set -eoux pipefail

IMAGE_INFO="$(cat /usr/share/ublue-os/image-info.json)"
IMAGE_TAG="$(jq -c -r '."image-tag"' <<<"$IMAGE_INFO")"
IMAGE_REF="$(jq -c -r '."image-ref"' <<<"$IMAGE_INFO")"
IMAGE_REF="${IMAGE_REF##*://}"
sbkey='https://github.com/ublue-os/akmods/raw/main/certs/public_key.der'

# Configure Live Environment
glib-compile-schemas /usr/share/glib-2.0/schemas

systemctl disable rpm-ostree-countme.service || true
systemctl disable tailscaled || true
systemctl disable netbird || true
systemctl disable bootloader-update.service || true
systemctl disable brew-upgrade.timer || true
systemctl disable brew-update.timer || true
systemctl disable brew-setup.service || true
systemctl disable rpm-ostreed-automatic.timer || true
systemctl disable uupd.timer || true
systemctl disable ublue-system-setup.service || true
systemctl disable flatpak-preinstall.service || true
systemctl --global disable podman-auto-update.timer || true
systemctl --global disable ublue-user-setup.service || true
systemctl --global disable bazaar.service || true

# Configure Anaconda

SPECS=(
    "libblockdev-btrfs"
    "libblockdev-lvm"
    "libblockdev-dm"
    "anaconda-live"
    "anaconda-webui"
    "sway"
    "firefox"
    "bibata-cursor-themes"
)

# Always sync releasever with os-release — the image may ship a stale value after a rebase.
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ -n "${VERSION_ID:-}" ]]; then
        mkdir -p /etc/dnf/vars
        echo "$VERSION_ID" > /etc/dnf/vars/releasever
    fi
fi

dnf install -y dnf-plugins-core
dnf copr enable -y peterwu/rendezvous
dnf install -y "${SPECS[@]}"

# Patch webui-desktop:
# 1. Remove -e so a failing command (e.g. systemctl start webui-cockpit-ws) doesn't abort the script.
# 2. Guard DISPLAY against being unset when running on pure Wayland (no Xwayland yet).
# 3. Add trace logging so boot-time failures are diagnosable from /tmp/webui-desktop-debug.log.
sed -i 's|^set -eu$|set -u|' /usr/libexec/anaconda/webui-desktop
sed -i 's|DISPLAY=\$DISPLAY|DISPLAY="${DISPLAY:-}"|g' /usr/libexec/anaconda/webui-desktop
sed -i '2a exec 2>>/tmp/webui-desktop-debug.log\nset -x' /usr/libexec/anaconda/webui-desktop

# The WebUI (slitherer) must run as liveuser, so we need a real logind session
# with /run/user/1000, user systemd, and D-Bus — only PAM login provides all of
# that. Use agetty autologin on tty1: PAM creates the full session, then
# liveuser's .bash_profile starts kwin_wayland + liveinst directly.
systemctl disable plasmalogin.service || true

# pkexec (liveinst → root, webui-desktop → liveuser) needs polkit.Result.YES
# so it can run without an interactive agent. Safe for an ephemeral live session.
mkdir -p /etc/polkit-1/rules.d
tee /etc/polkit-1/rules.d/00-live-installer.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id === "org.freedesktop.policykit.exec" && subject.local) {
        return polkit.Result.YES;
    }
});
EOF

mkdir -p /etc/systemd/system/getty@tty1.service.d
tee /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Unit]
After=livesys-late.service
Wants=livesys-late.service

[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
EOF

mkdir -p /var/lib/livesys/livesys-session-extra.d
tee /var/lib/livesys/livesys-session-extra.d/90-installer-session.sh <<'EOF'
#!/bin/bash
mkdir -p /root/.config/sway
cat > /root/.config/sway/config << 'SWAYCONF'
xwayland enable
default_border none
seat * xcursor_theme Bibata-Modern-Classic 20
# Import WAYLAND_DISPLAY into user@0's systemd environment so webui-desktop's
# pkexec env call (which reads systemctl --user show-environment) picks it up
# and passes it through to Firefox.
exec systemctl --user import-environment WAYLAND_DISPLAY
exec sh -c 'sleep 2 && liveinst'
SWAYCONF

cat > /root/.bash_profile << 'PROFILE'
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_RUNTIME_DIR=/run/user/0
    mkdir -p "$XDG_RUNTIME_DIR"
    # Ensure root's user systemd session exists for systemctl --user in webui-desktop
    systemctl start user@0.service 2>/dev/null || true
    # Tell webui-desktop to use root (UID 0) as the installer user, so Firefox
    # runs in the same session as sway (not as liveuser who can't reach our display)
    export PKEXEC_UID=0
    export WLR_RENDERER=pixman
    export WLR_NO_HARDWARE_CURSORS=1
    exec dbus-run-session sway --unsupported-gpu
fi
PROFILE
EOF
chmod +x /var/lib/livesys/livesys-session-extra.d/90-installer-session.sh

# Set hostname
echo "blossomos" | tee /etc/hostname

# Anaconda Profile for BlossomOS

tee /etc/anaconda/profile.d/blossomos.conf <<'EOF'
# Anaconda configuration file for BlossomOS

[Profile]
profile_id = blossomos
base_profile = fedora

[Profile Detection]
# Match os-release values (ID=blossomos set in os-release by build script)
os_id = blossomos

[Network]
default_on_boot = FIRST_WIRED_WITH_LINK

[Bootloader]
efi_dir = fedora
menu_auto_hide = True

[Storage]
default_scheme = BTRFS
btrfs_compression = zstd:1
default_partitioning =
    /     (min 1 GiB, max 70 GiB)
    /home (min 500 MiB, free 50 GiB)
    /var  (btrfs)

[User Interface]
webui_web_engine = firefox
custom_stylesheet =
hidden_spokes =
    NetworkSpoke
    PasswordSpoke
hidden_webui_pages =
    root-password
    network
EOF

# Disable user creation since it's being handled by plasma-setup
sed -i '/hidden_spokes =/a \    UserSpoke' /etc/anaconda/profile.d/blossomos.conf
sed -i '/hidden_webui_pages =/a \    anaconda-screen-accounts' /etc/anaconda/profile.d/blossomos.conf

# Configure system-release
# Also set ID=blossomos so anaconda profile detection matches our profile.d/blossomos.conf
# (it would otherwise match fedora-kde.conf via ID=fedora, inheriting webui_web_engine=slitherer).
. /etc/os-release
sed -i 's/^ID=fedora$/ID=blossomos/' /etc/os-release
echo "BlossomOS release $VERSION_ID ($VERSION_CODENAME)" >/etc/system-release

# Set Anaconda product name
mkdir -p /etc/anaconda/product.d
tee /etc/anaconda/product.d/blossomos-product.conf <<'EOF'
[Product]
product_name = BlossomOS
EOF

# Users can mess with flatpaks on the live environment which will get
# carried over to the installed system
cp -a /var/lib/flatpak /var/lib/flatpak_original

# Interactive Kickstart
tee -a /usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=$IMAGE_REF:$IMAGE_TAG --transport=containers-storage --no-signature-verification
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks
EOF

# Switch to signed image after install
tee /usr/share/anaconda/post-scripts/install-configure-upgrade.ks <<EOF
%post --erroronfail
bootc switch --mutate-in-place --enforce-container-sigpolicy --transport registry $IMAGE_REF:$IMAGE_TAG
%end
EOF

# Disable Fedora Flatpak remote
tee /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks <<'EOF'
%post --erroronfail
systemctl disable flatpak-add-fedora-repos.service
%end
EOF

# Copy pre-installed flatpaks into the installed system
tee /usr/share/anaconda/post-scripts/install-flatpaks.ks <<'EOF'
%post --erroronfail --nochroot
deployment="$(ostree rev-parse --repo=/mnt/sysimage/ostree/repo ostree/0/1/0)"
target="/mnt/sysimage/ostree/deploy/default/deploy/$deployment.0/var/lib/"
mkdir -p "$target"
rsync -aAXUHKP /var/lib/flatpak_original/ "$target/flatpak"
sync
%end
EOF

# Fetch the Secureboot Public Key
curl --retry 15 -Lo /etc/sb_pubkey.der "$sbkey"

# Enroll Secureboot Key
tee /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks <<'EOF'
%post --erroronfail --nochroot
set -oue pipefail

readonly ENROLLMENT_PASSWORD="universalblue"
readonly SECUREBOOT_KEY="/etc/sb_pubkey.der"

if [[ ! -d "/sys/firmware/efi" ]]; then
    echo "EFI mode not detected. Skipping key enrollment."
    exit 0
fi

if [[ ! -f "$SECUREBOOT_KEY" ]]; then
    echo "Secure boot key not provided: $SECUREBOOT_KEY"
    exit 0
fi

SYS_ID="$(cat /sys/devices/virtual/dmi/id/product_name)"
if [[ ":Jupiter:Galileo:" =~ ":$SYS_ID:" ]]; then
    echo "Steam Deck hardware detected. Skipping key enrollment."
    exit 0
fi

mokutil --timeout -1 || :
echo -e "$ENROLLMENT_PASSWORD\n$ENROLLMENT_PASSWORD" | mokutil --import "$SECUREBOOT_KEY" || :
%end
EOF
