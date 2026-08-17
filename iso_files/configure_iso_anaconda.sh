#!/usr/bin/env bash

set -eoux pipefail

IMAGE_INFO="/usr/share/ublue-os/image-info.json"
IMAGE_FLAVOR=$(jq -r '."image-flavor" // "main"' "$IMAGE_INFO")
IMAGE_NAME=$(jq -r '."image-name" // ""' "$IMAGE_INFO")
if [[ "$IMAGE_NAME" == blossomos-* ]]; then
    variant="${IMAGE_NAME#blossomos-}"
    IMAGE_TAG="main${variant:+-$variant}"
else
    IMAGE_TAG="main"
fi
IMAGE_TAG="${IMAGE_TAG/-open/}"
IMAGE_REF="registry.blossomos.org/blossom/image:${IMAGE_TAG}"
sbkey='https://github.com/ublue-os/akmods/raw/main/certs/public_key.der'

# Configure Live Environment
glib-compile-schemas /usr/share/glib-2.0/schemas

systemctl disable rpm-ostree-countme.service || true
systemctl disable tailscaled || true
systemctl disable netbird || true
systemctl disable mullvad || true
systemctl disable bootloader-update.service || true
systemctl disable brew-upgrade.timer || true
systemctl disable brew-update.timer || true
systemctl disable brew-setup.service || true
systemctl disable rpm-ostreed-automatic.timer || true
systemctl disable uupd.timer || true
systemctl disable ublue-system-setup.service || true
systemctl disable flatpak-preinstall.service || true
systemctl disable system-flatpak-setup.service || true
systemctl --global disable podman-auto-update.timer || true
systemctl --global disable ublue-user-setup.service || true
systemctl --global disable bazaar.service || true

# Configure Anaconda

SPECS=(
    "libblockdev-btrfs"
    "libblockdev-lvm"
    "libblockdev-dm"
    "anaconda-live"
    "firefox"
    "xkeyboard-config"
    "python3-xkbregistry"
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

# Custom Anaconda WebUI
shopt -s nullglob
webui_rpms=(/app/anaconda-webui-*.rpm)
shopt -u nullglob
if (( ${#webui_rpms[@]} > 0 )); then
    echo "Installing local anaconda-webui: ${webui_rpms[*]}"
    dnf install -y --nogpgcheck "${webui_rpms[@]}"
else
    echo "Build failed: no anaconda-webui RPM staged"
    exit 1
fi

# Patch webui-desktop:
# 1. Remove -e so a failing command (e.g. systemctl start webui-cockpit-ws) doesn't abort the script.
# 2. Guard DISPLAY against being unset when running on pure Wayland (no Xwayland yet).
# 3. Add trace logging so boot-time failures are diagnosable from /tmp/webui-desktop-debug.log.
sed -i 's|^set -eu$|set -u|' /usr/libexec/anaconda/webui-desktop
sed -i 's|DISPLAY=\$DISPLAY|DISPLAY="${DISPLAY:-}"|g' /usr/libexec/anaconda/webui-desktop
sed -i '2a exec 2>>/tmp/webui-desktop-debug.log\nset -x' /usr/libexec/anaconda/webui-desktop

# Then remove firefox from the applications list so it isn't the default browser
rm /usr/share/applications/org.mozilla.firefox.desktop

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

mkdir -p /var/lib/livesys/livesys-session-extra.d
tee /var/lib/livesys/livesys-session-extra.d/90-installer-session.sh <<'EOF'
#!/bin/bash

# Seed XLayouts so anaconda's keyboard picker renders with a default layout.
# plannedXlayouts comes from the XLayouts D-Bus property; if empty the Keyboard
# component returns null even though the section label is visible.
# The user can still select any layout in the installer — this is just the default.
localectl set-keymap us 2>/dev/null || true
localectl set-x11-keymap us 2>/dev/null || true
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
sed -i 's/^ID=.*$/ID=blossomos/' /etc/os-release
echo "BlossomOS release $VERSION_ID ($VERSION_CODENAME)" >/etc/system-release

# Set Anaconda product name
mkdir -p /etc/anaconda/product.d
tee /etc/anaconda/product.d/blossomos-product.conf <<'EOF'
[Product]
product_name = BlossomOS
EOF

# Install flatpaks from the custom blossomos remote.
# Titanoboa's rootfs-include-flatpaks only adds Flathub and silently skips
# anything not found there, so custom-remote packages must be installed here.
flatpak remote-add --system --if-not-exists blossomos \
    https://forge.arcstore.net/flatpak.flatpakrepo
flatpak install --system --noninteractive -y blossomos \
    net.imput.helium \
    runtime/org.kde.KStyle.BlossomUI/x86_64/6.9 \
    runtime/org.kde.KStyle.BlossomUI/x86_64/5.15-24.08 \
    || true

# Users can mess with flatpaks on the live environment which will get
# carried over to the installed system
cp -a /var/lib/flatpak /var/lib/flatpak_original

# Interactive Kickstart
tee -a /usr/share/anaconda/interactive-defaults.ks <<EOF
%pre-install
# containers-storage transport stages blobs in /var/tmp before committing to
# the ostree sysroot. The live system's /var/tmp is a small tmpfs — not big
# enough for a full bootc image. Bind-mount a dir on the already-formatted
# target root so ostree gets disk-backed staging space instead.
mkdir -p /mnt/sysimage/.ostree-staging
mount --bind /mnt/sysimage/.ostree-staging /var/tmp
%end

ostreecontainer --url=$IMAGE_REF --transport=containers-storage --no-signature-verification
bootloader --append="quiet splash"
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/configure-grub.ks
%include /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks
EOF

# Switch to signed image after install
tee /usr/share/anaconda/post-scripts/install-configure-upgrade.ks <<EOF
%post --erroronfail
bootc switch --mutate-in-place --transport registry $IMAGE_REF
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

# GRUB defaults for the installed system
tee /usr/share/anaconda/post-scripts/configure-grub.ks <<'EOF'
%post --erroronfail
set -oue pipefail

grub_defaults="/etc/default/grub"
touch "$grub_defaults"

set_grub_default() {
    if grep -q "^$1=" "$grub_defaults"; then
        sed -i "s|^$1=.*|$1=$2|" "$grub_defaults"
    else
        echo "$1=$2" >>"$grub_defaults"
    fi
}

# Without this a regenerated config drops the BLS entries and the system
# has nothing left to boot.
set_grub_default GRUB_ENABLE_BLSCFG true

# Plymouth
set_grub_default GRUB_CMDLINE_LINUX_DEFAULT '"quiet splash"'
set_grub_default GRUB_GFXPAYLOAD_LINUX keep

# grub 2.06 and later skip 30_os-prober entirely unless this is false.
set_grub_default GRUB_DISABLE_OS_PROBER false

# os-prober also reports the system we just installed, since anaconda has the
# target root mounted while this runs. Drop our own device from the results.
self_dev="$(findmnt -no SOURCE / 2>/dev/null || true)"
self_dev="${self_dev%%[*}"
other_os="$(os-prober 2>/dev/null || true)"
if [[ -n "$self_dev" && -n "$other_os" ]]; then
    other_os="$(grep -v "^${self_dev}:" <<<"$other_os" || true)"
fi

# Boot straight through on a single OS machine, but show a real menu when something else is installed so it can actually be selected.
if [[ -n "$other_os" ]]; then
    echo "Other operating systems detected, enabling the GRUB menu:"
    echo "$other_os"
    set_grub_default GRUB_TIMEOUT 5
    set_grub_default GRUB_TIMEOUT_STYLE menu
    # menu_auto_hide comes from the anaconda profile and would hide the menu
    # again regardless of the timeout.
    for grubenv in /boot/grub2/grubenv /boot/efi/EFI/fedora/grubenv; do
        if [[ -f "$grubenv" ]]; then
            grub2-editenv "$grubenv" unset menu_auto_hide || true
        fi
    done
else
    set_grub_default GRUB_TIMEOUT 0
    set_grub_default GRUB_TIMEOUT_STYLE hidden
fi

# The kernel cmdline itself comes from the BLS entries on an ostree system, so quiet splash is applied via bootloader append in the kickstart.
grub_cfg="/boot/grub2/grub.cfg"
if [[ ! -f "$grub_cfg" ]]; then
    grub_cfg="/boot/efi/EFI/fedora/grub.cfg"
fi
grub2-mkconfig -o "$grub_cfg" || true
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
