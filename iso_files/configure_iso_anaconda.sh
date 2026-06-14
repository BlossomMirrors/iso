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
    "anaconda-webui"
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
custom_stylesheet = /usr/share/anaconda/pixmaps/blossomos.css
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

# BlossomOS branding CSS for the installer WebUI.
# The first page section holds the installation title ("BlossomOS X installation").
# Without this file the text is white-on-white because the base CSS sets --_text:white
# assuming a dark background that was previously provided by fedora.scss.
mkdir -p /usr/share/anaconda/pixmaps
tee /usr/share/anaconda/pixmaps/blossomos.css <<'EOF'
/* ── Installation title header ── */
.pf-v6-c-page__main-group > .pf-v6-c-page__main-section:first-child {
    background: #18181F;
    --_text: white;
}
.pf-v6-c-page__main-group > .pf-v6-c-page__main-section:first-child svg path {
    color: var(--_text);
}

/* ── Wizard sidebar: dark ── */
.pf-v6-c-wizard__nav {
    background: #0C0C12;
    border-right: 1px solid #27272F;
}
.pf-v6-c-wizard__nav-link {
    color: #91919E;
    border-radius: 6px;
    transition: background 0.15s ease, color 0.15s ease;
}
.pf-v6-c-wizard__nav-link:hover {
    background: #18181F;
    color: #C2C2CA;
}
.pf-v6-c-wizard__nav-link.pf-m-current {
    background: #18181F;
    color: #ffffff;
}
.pf-v6-c-wizard__nav-link.pf-m-current::before {
    background-color: #1451FF;
}
/* Step numbers on dark sidebar */
.pf-v6-c-wizard__nav-item-count {
    color: #62626E;
}
.pf-v6-c-wizard__nav-link.pf-m-current .pf-v6-c-wizard__nav-item-count {
    color: #6798FF;
}

/* ── Page / content area ── */
.pf-v6-c-wizard__main-body,
.pf-v6-c-page__main-section {
    background: #ffffff;
}

/* ── Form inputs ── */
.pf-v6-c-form-control {
    border-radius: 6px !important;
    border-color: #C2C2CA;
    transition: border-color 0.15s, box-shadow 0.15s;
}
.pf-v6-c-form-control:focus-within {
    border-color: #1451FF;
    box-shadow: 0 0 0 2px rgba(20, 81, 255, 0.15);
    outline: none;
}
.pf-v6-c-form__label-text {
    font-weight: 500;
    color: #27272F;
}

/* ── Select toggles & menus ── */
.pf-v6-c-select__toggle,
.pf-v6-c-menu-toggle {
    border-radius: 6px !important;
    border-color: #C2C2CA;
}
.pf-v6-c-menu-toggle:hover,
.pf-v6-c-select__toggle:hover {
    border-color: #91919E;
}
.pf-v6-c-menu {
    border-radius: 8px;
    border: 1px solid #EDEDF0;
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.10), 0 2px 8px rgba(0, 0, 0, 0.06);
}
.pf-v6-c-menu__item:hover,
.pf-v6-c-menu__item.pf-m-focus {
    background: #EDEDF0;
}
.pf-v6-c-menu__item-check svg {
    color: #1451FF;
}

/* ── Buttons ── */
.pf-v6-c-button {
    border-radius: 6px !important;
    font-weight: 500;
    letter-spacing: 0.01em;
    transition: background 0.15s ease, box-shadow 0.15s ease;
}
.pf-v6-c-button.pf-m-primary {
    background: #1451FF;
    border-color: #1451FF;
    color: #ffffff;
    --pf-v6-c-button--m-primary--BackgroundColor: #1451FF;
    --pf-v6-c-button--m-primary--hover--BackgroundColor: #000DFF;
    --pf-v6-c-button--m-primary--active--BackgroundColor: #0007C5;
}
.pf-v6-c-button.pf-m-primary:hover {
    background: #000DFF;
    border-color: #000DFF;
    box-shadow: 0 2px 12px rgba(20, 81, 255, 0.35);
}
.pf-v6-c-button.pf-m-secondary {
    border-color: #3E78FF;
    color: #3E78FF;
    --pf-v6-c-button--m-secondary--BorderColor: #3E78FF;
    --pf-v6-c-button--m-secondary--Color: #3E78FF;
}
.pf-v6-c-button.pf-m-secondary:hover {
    border-color: #1451FF;
    color: #1451FF;
    background: rgba(62, 120, 255, 0.05);
}
.pf-v6-c-button.pf-m-link {
    color: #3E78FF;
}
.pf-v6-c-button.pf-m-link:hover {
    color: #1451FF;
}

/* ── Cards ── */
.pf-v6-c-card {
    border-radius: 10px;
    border: 1px solid #EDEDF0;
    box-shadow: 0 1px 4px rgba(0, 0, 0, 0.05);
}

/* ── Typography ── */
.pf-v6-c-title,
h1, h2, h3 {
    font-weight: 600;
    letter-spacing: -0.01em;
    color: #18181F;
}

/* ── Focus ring ── */
:focus-visible {
    outline-color: #3E78FF !important;
    outline-offset: 2px;
}

/* ── Links ── */
a {
    color: #3E78FF;
    text-decoration: none;
}
a:hover {
    color: #1451FF;
    text-decoration: underline;
}

/* ── Checkboxes & radios ── */
.pf-v6-c-check__input:checked,
.pf-v6-c-radio__input:checked {
    accent-color: #1451FF;
}

/* ── Alerts ── */
.pf-v6-c-alert {
    border-radius: 8px;
}
EOF

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
    https://repo.blossomos.org/blossomos.flatpakrepo
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
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/install-flatpaks.ks
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
