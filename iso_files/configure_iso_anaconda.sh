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
systemctl disable tailscaled.service || true
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
)

# Always sync releasever with os-release — the image may ship a stale value after a rebase.
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ -n "${VERSION_ID:-}" ]]; then
        mkdir -p /etc/dnf/vars
        echo "$VERSION_ID" > /etc/dnf/vars/releasever
    fi
fi

dnf install -y "${SPECS[@]}"

# Disable the Plasma login manager and boot straight into Anaconda
systemctl disable plasmalogin.service fedora-kinoite-plasmalogin-workaround.service || true
systemctl set-default anaconda.target

# anaconda.service needs a Wayland compositor (for slitherer/WebUI) but anaconda.target
# doesn't provide one. Start kwin_wayland in DRM mode as root before Anaconda.
mkdir -p /etc/systemd/system
tee /etc/systemd/system/anaconda-compositor.service <<'EOF'
[Unit]
Description=Wayland Compositor for Anaconda WebUI
Before=anaconda.service
After=systemd-logind.service

[Service]
Type=simple
Environment=HOME=/root XDG_RUNTIME_DIR=/run/user/0
ExecStartPre=/usr/bin/mkdir -p /run/user/0
ExecStartPre=/usr/bin/chmod 0700 /run/user/0
ExecStart=/usr/bin/kwin_wayland --drm --no-lockscreen --no-global-shortcuts --no-kactivities
Restart=on-failure
RestartSec=2

[Install]
WantedBy=anaconda.target
EOF
systemctl enable anaconda-compositor.service

# Anaconda Profile for BlossomOS

tee /etc/anaconda/profile.d/blossomos.conf <<'EOF'
# Anaconda configuration file for BlossomOS

[Profile]
profile_id = blossomos

[Profile Detection]
# Match os-release values
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
webui_web_engine = slitherer
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
. /etc/os-release
echo "BlossomOS release $VERSION_ID ($VERSION_CODENAME)" >/etc/system-release

sed -i 's/ANACONDA_PRODUCTNAME=.*/ANACONDA_PRODUCTNAME="BlossomOS"/' /usr/{,s}bin/liveinst || true
sed -i 's/ANACONDA_PRODUCTVERSION=.*/ANACONDA_PRODUCTVERSION=""/' /usr/{,s}bin/liveinst || true

# Set Anaconda product name for WebUI branding
mkdir -p /etc/anaconda/product.d
tee /etc/anaconda/product.d/blossomos-product.conf <<'EOF'
[Product]
product_name = BlossomOS
EOF

# Add StartupWMClass so the running window inherits the icon
desktop-file-edit \
    --set-key=StartupWMClass --set-value=slitherer \
    /usr/share/applications/liveinst.desktop

# Disable kwallet in live session
tee -a /etc/xdg/kwalletrc <<EOF
[Wallet]
Enabled=false
EOF

# Users can mess with flatpaks on the live environment which will get
# carried over to the installed system
cp -a /var/lib/flatpak /var/lib/flatpak_original

# Interactive Kickstart
tee -a /usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=$IMAGE_REF --tag=$IMAGE_TAG --transport=containers-storage --no-signature-verification
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
