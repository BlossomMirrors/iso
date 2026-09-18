#!/usr/bin/env bash

set -eoux pipefail

# kernel-blossomos' vmlinuz is signed against this cert (see image repo's
# build_files/base/02-install-common-kernel-akmods.sh), not ublue-os' akmods
# key. A netinstall ISO's live rootfs is plain fedora-bootc and never has the
# image's own /usr/share/blossomos/secureboot on it, so this is fetched the
# same way generate-flatpak-list already pulls a static file straight out of
# the image repo.
sbkey='https://dev.blossomos.org/blossom/os/core/image/-/raw/release/secureboot.der'

# The rootfs's own /usr/share/ublue-os/image-info.json can't tell us which
# tag (stable/latest/beta/main, with or without an nvidia suffix) was
# actually requested — the Justfile already knows, so it's passed straight
# through instead of re-derived here. A previous version of this script
# reconstructed it by guessing from image-info.json and always fell back to
# "main", so e.g. requesting tag=latest still silently installed :main.
IMAGE_TAG="main"
if [[ -f /app/.blossomos-image-tag ]]; then
    IMAGE_TAG="$(cat /app/.blossomos-image-tag)"
fi
IMAGE_REF="registry.blossomos.org/blossom/image:${IMAGE_TAG}"

LIVE_SESSION=1
if [[ -f /app/.blossomos-live ]]; then
    LIVE_SESSION="$(cat /app/.blossomos-live)"
fi

NETINSTALL=1
if [[ -f /app/.blossomos-netinstall ]]; then
    NETINSTALL="$(cat /app/.blossomos-netinstall)"
fi

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

if [[ "$LIVE_SESSION" == "0" ]]; then
    systemctl mask getty@tty6.service autovt@tty6.service
fi

SPECS=(
    "libblockdev-btrfs"
    "libblockdev-lvm"
    "libblockdev-dm"
    "firefox"
    "xkeyboard-config"
    "python3-xkbregistry"
)
if [[ "$LIVE_SESSION" == "1" ]]; then
    SPECS+=("anaconda-live")
else
    # pciutils is for lspci, used by the netinstall GPU-detection %pre script
    # further down (harmless to have even for netinstall=0, where it's unused).
    SPECS+=("gnome-kiosk" "python3-pam" "pciutils")
fi

if [[ "$NETINSTALL" == "1" ]]; then
    # This rootfs is the minimal fedora-bootc base rather than the full
    # BlossomOS/Kinoite image, so packages the full image ships by default
    # (and that anaconda / our own overrides below assume exist) need to be
    # pulled in explicitly here. Redundant but harmless for netinstall=0,
    # since that path already has all of this via the real image.
    SPECS+=(
        # anaconda.service's ExecStart is a tmux session (anaconda's text
        # console mechanism).
        "tmux"
        # Real ALSA hardware routing/mixer support for pipewire. pipewire
        # and wireplumber themselves already come in transitively via
        # gnome-kiosk, but without these, playback silently produces no
        # sound on real hardware.
        "alsa-ucm" "alsa-utils" "alsa-sof-firmware" "pipewire-alsa"
        # Bibata-Modern-Classic, set as the default cursor theme further
        # down. Comes from the peterwu/rendezvous COPR enabled further below,
        # before the actual "dnf install \"${SPECS[@]}\"" call runs.
        "bibata-cursor-themes"
        # Non-Latin script coverage, matching ../image's own font selection
        # (core/image build_files/base/packages.dnf) plus Arabic.
        "google-noto-sans-cjk-fonts" "google-noto-sans-arabic-fonts"
        "google-noto-sans-balinese-fonts" "google-noto-sans-javanese-fonts"
        "google-noto-sans-sundanese-fonts" "google-noto-emoji-fonts"
    )
fi

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ -n "${VERSION_ID:-}" ]]; then
        mkdir -p /etc/dnf/vars
        echo "$VERSION_ID" > /etc/dnf/vars/releasever
    fi
fi

is_final=true
if [[ "${PRETTY_NAME:-}" =~ (Alpha|Beta|RC) ]]; then
    is_final=false
fi
printf '[Main]\nIsFinal=%s\n' "$is_final" > /.buildstamp

# dnf-plugins-core is the dnf4 copr plugin; this system's dnf is dnf5, whose
# copr command comes from dnf5-plugins instead. Never caught before now
# because the full blossomos/kinoite image already ships it; the netinstall
# minimal fedora-bootc base doesn't.
dnf install -y dnf5-plugins
dnf copr enable -y peterwu/rendezvous
dnf install -y "${SPECS[@]}"

if [[ "$NETINSTALL" == "1" ]]; then
    # Aspekta and Lora (see ../image build_files/base/04-blossomos.sh) ship
    # inside the blossomui RPM, which also pulls in the full KDE/Qt desktop
    # style stack (kstyle5/6, icons, wallpapers) — nothing this minimal
    # install environment has any use for. Download just the RPM and extract
    # the font files directly instead of a full package install.
    rpm --import https://repo.blossomos.org/BLOSSOMOS-GPG-KEY.pub
    tee /etc/yum.repos.d/blossom.repo <<'EOF'
[blossomos-main]
name=BlossomOS Main
baseurl=https://repo.blossomos.org/rpm/
enabled=0
gpgcheck=1
gpgkey=https://repo.blossomos.org/BLOSSOMOS-GPG-KEY.pub
EOF
    mkdir -p /tmp/blossomui-dl
    dnf5 download --destdir=/tmp/blossomui-dl --enablerepo=blossomos-main blossomui
    (cd / && rpm2cpio /tmp/blossomui-dl/blossomui-*.rpm | cpio -idm --quiet \
        './usr/share/fonts/blossomui/aspekta/*' './usr/share/fonts/blossomui/lora/*')
    rm -rf /tmp/blossomui-dl /etc/yum.repos.d/blossom.repo
fi

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

if [[ "$LIVE_SESSION" == "0" ]]; then
    tee /usr/share/glib-2.0/schemas/zz1-blossomos-cursor.gschema.override <<'EOF'
[org.gnome.desktop.interface]
cursor-theme='Bibata-Modern-Classic'
cursor-size=20
EOF

    # pipewire.service isn't actually the gatekeeper here — it's socket-
    # activated, and pipewire.socket, pipewire-pulse.socket and
    # pipewire-pulse.service all separately ship their own ConditionUser=!root
    # too. Missing any one of them means pipewire never actually activates
    # when this whole install environment runs as root, with no user account.
    for unit in pipewire.service pipewire.socket pipewire-pulse.socket pipewire-pulse.service; do
        mkdir -p "/usr/lib/systemd/user/${unit}.d"
        tee "/usr/lib/systemd/user/${unit}.d/10-allow-root.conf" <<'EOF'
[Unit]
ConditionUser=
EOF
    done
    systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service

    # WirePlumber's own default (device.routes.default-sink-volume, see
    # /usr/share/wireplumber/wireplumber.conf) is 0.064 — barely audible.
    # The WebUI's own install music already plays at full volume in-page, and
    # there's no desktop with a volume dial/tray to fix this by hand, so give
    # it a real, hardcoded default instead.
    mkdir -p /usr/share/wireplumber/wireplumber.conf.d
    tee /usr/share/wireplumber/wireplumber.conf.d/blossomos-default-volume.conf <<'EOF'
wireplumber.settings = {
  device.routes.default-sink-volume = 0.48
}
EOF
fi

glib-compile-schemas /usr/share/glib-2.0/schemas

sed -i 's|^set -eu$|set -u|' /usr/libexec/anaconda/webui-desktop
sed -i 's|DISPLAY=\$DISPLAY|DISPLAY="${DISPLAY:-}"|g' /usr/libexec/anaconda/webui-desktop
sed -i '2a exec 2>>/tmp/webui-desktop-debug.log\nset -x' /usr/libexec/anaconda/webui-desktop

if [[ "$LIVE_SESSION" == "0" ]]; then
    # Upstream launches Firefox as a normal window (address bar, tabs, window
    # controls) — on gnome-kiosk there's no desktop around it, so moving the
    # mouse to the top just reveals a title bar the user can accidentally hit
    # close on. --kiosk removes all of that for a true fullscreen installer.
    sed -i 's|--new-instance --profile|--new-instance --kiosk --profile|' /usr/libexec/anaconda/webui-desktop
fi

rm /usr/share/applications/org.mozilla.firefox.desktop

for theme in default live extlink; do
    theme_js="/usr/share/anaconda/firefox-theme/${theme}/user.js"
    if [[ -f "$theme_js" ]]; then
        echo 'user_pref("browser.translations.enable", false);' >> "$theme_js"
        # Right-click's context menu offers reload/back/view-source/inspect —
        # none of it useful in the installer, all of it a way to get stuck
        # or navigate away from it.
        echo 'user_pref("dom.event.contextmenu.enabled", false);' >> "$theme_js"
    fi
done

if [[ "$LIVE_SESSION" == "1" ]]; then
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
localectl set-keymap us 2>/dev/null || true
localectl set-x11-keymap us 2>/dev/null || true
EOF
    chmod +x /var/lib/livesys/livesys-session-extra.d/90-installer-session.sh

    mkdir -p /etc/xdg/autostart
    tee /etc/xdg/autostart/blossomos-liveinst-autostart.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Install BlossomOS
Exec=/usr/bin/liveinst
NoDisplay=true
EOF
fi

echo "blossomos" | tee /etc/hostname

tee /etc/anaconda/profile.d/blossomos.conf <<'EOF'
[Profile]
profile_id = blossomos
base_profile = fedora

[Profile Detection]
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
    PasswordSpoke
hidden_webui_pages =
    root-password
EOF

sed -i '/hidden_spokes =/a \    UserSpoke' /etc/anaconda/profile.d/blossomos.conf
sed -i '/hidden_webui_pages =/a \    anaconda-screen-accounts' /etc/anaconda/profile.d/blossomos.conf

if [[ "$NETINSTALL" == "0" ]]; then
    # The image is staged locally, so there's nothing to fetch and the
    # network step is pointless. With NETINSTALL=1 (default) the install
    # source is fetched over the network — keep the step so WiFi-only
    # machines with no wired link have a way to get connected first.
    sed -i '/hidden_spokes =/a \    NetworkSpoke' /etc/anaconda/profile.d/blossomos.conf
    sed -i '/hidden_webui_pages =/a \    anaconda-screen-network' /etc/anaconda/profile.d/blossomos.conf
fi

. /etc/os-release
sed -i 's/^ID=.*$/ID=blossomos/' /etc/os-release
echo "BlossomOS release $VERSION_ID ($VERSION_CODENAME)" >/etc/system-release

mkdir -p /etc/anaconda/product.d
tee /etc/anaconda/product.d/blossomos-product.conf <<'EOF'
[Product]
product_name = BlossomOS
EOF

if [[ "$LIVE_SESSION" == "0" && "$NETINSTALL" == "0" ]]; then
    # Only applies to offline builds (netinstall=0): those still extract the
    # full flavor-specific BlossomOS image as rootfs (see the Justfile), so
    # Plasma needs stripping back out. netinstall=1 boots a minimal
    # fedora-bootc rootfs with no KDE in it in the first place — running this
    # against it would just print ~90 harmless "No packages to remove" lines.
    #
    # The installed system gets the full image fresh via ostreecontainer below,
    # so Plasma in this live/install rootfs is dead weight — it's never booted
    # into. `dnf5 group remove` can't drop it: this rootfs came from container
    # layers rather than a real `group install` transaction, so dnf5 has no
    # local record of any group being installed and always reports "No groups
    # to remove", regardless of which group ID is given.
    #
    # This is the "kde-desktop" comps group's own member list (`dnf5 group
    # info kde-desktop`), with two packages pulled back out because removing
    # them breaks things we actually need: glibc-all-langpacks (removing it
    # drags glibc itself into the transaction, which drags out the entire
    # system) and udisks2 (anaconda-webui hard-requires cockpit-storaged,
    # which requires udisks2). The --exclude list below is a second line of
    # defense against the same kind of collision if the base image's package
    # set drifts later — confirmed via `dnf5 remove ... --assumeno` that this
    # exact list resolves cleanly and frees ~1 GiB without touching any of it.
    kde_packages=(
        kcm-plasmalogin plasma-desktop plasma-login-manager plasma-setup
        plasma-workspace plasma-workspace-wallpapers
        NetworkManager-config-connectivity-fedora PackageKit-command-not-found
        abrt-desktop akonadi-server akonadi-server-mysql ark audiocd-kio
        aurorae bluedevil breeze-icon-theme colord-kde cups-pk-helper dolphin
        fedora-flathub-remote fedora-workstation-repositories ffmpegthumbs
        filelight firewall-config flatpak-kcm fprintd-pam
        kaccounts-integration-qt6 kaccounts-providers kcharselect kde-connect
        kde-gtk-config kde-inotify-survey kde-partitionmanager
        kde-settings-plasmalogin kde-settings-pulseaudio kdebugsettings
        kdegraphics-thumbnailers kdenetwork-filesharing kdeplasma-addons
        kdialog kdnssd kf6-baloo-file kfind khelpcenter kinfocenter kio-admin
        kio-gdrive kjournald kmenuedit konsole krdp krfb kscreen
        kscreenlocker ksshaskpass kunifiedpush kwalletmanager5 kwin kwrite
        libappindicator-gtk3 pam-kwallet phonon-qt6-backend-vlc pinentry-qt
        plasma-breeze plasma-desktop-doc plasma-discover
        plasma-discover-notifier plasma-disks plasma-drkonqi plasma-nm
        plasma-nm-l2tp plasma-nm-openconnect plasma-nm-openswan
        plasma-nm-openvpn plasma-nm-pptp plasma-nm-vpnc plasma-pa
        plasma-print-manager plasma-systemmonitor plasma-thunderbolt
        plasma-vault plasma-welcome polkit-kde samba-usershares
        signon-kwallet-extension spectacle systemd-oomd-defaults thermald
        toolbox vlc-plugin-gstreamer xwaylandvideobridge plasma-pk-updates
    )
    protected_packages=(
        anaconda-core anaconda-webui anaconda-tui libreport-anaconda
        python3-blivet python3-pyparted python3-kickstart python3-libdnf5
        python3-blockdev python3-bugzilla udisks2
    )
    protected_csv="$(IFS=,; echo "${protected_packages[*]}")"
    dnf5 remove -y "${kde_packages[@]}" --exclude="$protected_csv" \
        || echo "WARNING: KDE package removal failed, ISO will be larger than expected" >&2
fi

# A non-live netinstall build has no /var/lib/flatpak to snapshot here at all
# (rootfs-include-flatpaks is skipped in titanoboa for this case, see the
# install-flatpaks.ks generation below) — pre-staging flatpaks into a squashfs
# that only ever runs the installer would just re-inflate the ISO we're
# trying to shrink, and netinstall already requires network at install time
# anyway, so the target fetches them directly instead.
if [[ "$LIVE_SESSION" == "1" || "$NETINSTALL" == "0" ]]; then
    flatpak remote-add --system --if-not-exists blossomos \
        https://forge.arcstore.net/flatpak.flatpakrepo
    flatpak install --system --noninteractive -y blossomos \
        net.imput.helium \
        runtime/org.kde.KStyle.BlossomUI/x86_64/6.9 \
        runtime/org.kde.KStyle.BlossomUI/x86_64/5.15-24.08 \
        || true

    cp -a /var/lib/flatpak /var/lib/flatpak_original
fi

OSTREE_TRANSPORT="containers-storage"
if [[ "$NETINSTALL" == "1" ]]; then
    # No image staged into this rootfs's container storage (see the
    # rootfs-include-container skip in titanoboa) — pull it over the network
    # at install time instead, same as ostreecontainer would for any registry.
    OSTREE_TRANSPORT="registry"
fi

# netinstall=1 boots a flavor-independent minimal image (no GPU drivers
# baked in), so the actual flavor to install is decided at install time by
# probing the target machine's GPU instead of at build time. It also allows
# overriding the image reference entirely via a blossomos.oci_url= kernel
# arg (blossomos.oci_transport= for a non-default transport, e.g. when
# PXE-booting against a locally hosted OCI registry instead of
# registry.blossomos.org, see PXE.md) — GPU detection is skipped whenever
# that override is present, since the caller is naming the exact image.
#
# This can NOT be done with a %pre/%pre-install section writing a file for
# a later %include in the same kickstart, even though that's a commonly
# documented pattern elsewhere: anaconda parses interactive-defaults.ks as
# one upfront pass — %include is resolved textually as part of that parse,
# entirely before any %pre/%pre-install section has actually run (confirmed
# via anaconda.log: "Parsing kickstart" fails immediately with the %include
# target missing, before any section-execution log line appears at all).
#
# Instead, resolve the image reference before anaconda ever touches the
# kickstart file: a oneshot systemd service (Before=anaconda.target, same
# ordering anaconda-core's own anaconda-pre.service uses) runs the GPU
# detection / kernel arg check and sed-substitutes the real values into
# plain static placeholders in both interactive-defaults.ks and
# install-configure-upgrade.ks. Anaconda only ever sees already-resolved,
# static kickstart text.
#
# The legacy table below is every Maxwell/Pascal/Volta NVIDIA device ID
# (negativo17's proprietary "580" driver branch is the last to support
# them; upstream open kernel modules only cover Turing and later),
# hand-built from /usr/share/hwdata/pci.ids.
OSTREE_DIRECTIVE="ostreecontainer --url=$IMAGE_REF --transport=$OSTREE_TRANSPORT --no-signature-verification"
if [[ "$NETINSTALL" == "1" ]]; then
    OSTREE_DIRECTIVE="ostreecontainer --url=__BLOSSOMOS_IMAGE_REF__ --transport=__BLOSSOMOS_TRANSPORT__ --no-signature-verification"

    mkdir -p /usr/libexec/anaconda
    tee /usr/libexec/anaconda/blossomos-resolve-flavor <<'PREEOF'
#!/usr/bin/bash
set -euo pipefail
declare -A blossomos_legacy_nvidia=(
        ["1340"]=1 ["1341"]=1 ["1344"]=1 ["1346"]=1 ["1347"]=1 ["1348"]=1
        ["1349"]=1 ["134b"]=1 ["134d"]=1 ["134e"]=1 ["134f"]=1 ["137a"]=1
        ["137b"]=1 ["137d"]=1 ["1380"]=1 ["1381"]=1 ["1382"]=1 ["1389"]=1
        ["1390"]=1 ["1391"]=1 ["1392"]=1 ["1393"]=1 ["1398"]=1 ["1399"]=1
        ["139a"]=1 ["139b"]=1 ["139c"]=1 ["139d"]=1 ["13ad"]=1 ["13ae"]=1
        ["13b0"]=1 ["13b1"]=1 ["13b2"]=1 ["13b3"]=1 ["13b4"]=1 ["13b6"]=1
        ["13b9"]=1 ["13ba"]=1 ["13bb"]=1 ["13bc"]=1 ["13bd"]=1 ["13be"]=1
        ["13bf"]=1 ["13c0"]=1 ["13c1"]=1 ["13c2"]=1 ["13c3"]=1 ["13c4"]=1
        ["13d7"]=1 ["13d8"]=1 ["13d9"]=1 ["13da"]=1 ["13e4"]=1 ["13e7"]=1
        ["13f0"]=1 ["13f1"]=1 ["13f2"]=1 ["13f3"]=1 ["13f8"]=1 ["13f9"]=1
        ["13fa"]=1 ["13fb"]=1 ["1401"]=1 ["1402"]=1 ["1404"]=1 ["1406"]=1
        ["1407"]=1 ["1427"]=1 ["1430"]=1 ["1431"]=1 ["1436"]=1 ["15c2"]=1
        ["15f0"]=1 ["15f1"]=1 ["15f7"]=1 ["15f8"]=1 ["15f9"]=1 ["15fa"]=1
        ["15fb"]=1 ["15fc"]=1 ["15ff"]=1 ["1613"]=1 ["1617"]=1 ["1618"]=1
        ["1619"]=1 ["161a"]=1 ["1667"]=1 ["1676"]=1 ["1725"]=1 ["172e"]=1
        ["172f"]=1 ["174d"]=1 ["174e"]=1 ["1789"]=1 ["179c"]=1 ["17c2"]=1
        ["17c8"]=1 ["17f0"]=1 ["17f1"]=1 ["17fd"]=1 ["1b00"]=1 ["1b01"]=1
        ["1b02"]=1 ["1b04"]=1 ["1b06"]=1 ["1b07"]=1 ["1b30"]=1 ["1b38"]=1
        ["1b39"]=1 ["1b70"]=1 ["1b78"]=1 ["1b80"]=1 ["1b81"]=1 ["1b82"]=1
        ["1b83"]=1 ["1b84"]=1 ["1b87"]=1 ["1ba0"]=1 ["1ba1"]=1 ["1ba2"]=1
        ["1ba9"]=1 ["1baa"]=1 ["1bad"]=1 ["1bb0"]=1 ["1bb1"]=1 ["1bb3"]=1
        ["1bb4"]=1 ["1bb5"]=1 ["1bb6"]=1 ["1bb7"]=1 ["1bb8"]=1 ["1bb9"]=1
        ["1bbb"]=1 ["1bc7"]=1 ["1be0"]=1 ["1be1"]=1 ["1c00"]=1 ["1c01"]=1
        ["1c02"]=1 ["1c03"]=1 ["1c04"]=1 ["1c06"]=1 ["1c07"]=1 ["1c09"]=1
        ["1c20"]=1 ["1c21"]=1 ["1c22"]=1 ["1c23"]=1 ["1c2d"]=1 ["1c30"]=1
        ["1c31"]=1 ["1c35"]=1 ["1c36"]=1 ["1c60"]=1 ["1c61"]=1 ["1c62"]=1
        ["1c70"]=1 ["1c81"]=1 ["1c82"]=1 ["1c83"]=1 ["1c8c"]=1 ["1c8d"]=1
        ["1c8e"]=1 ["1c8f"]=1 ["1c90"]=1 ["1c91"]=1 ["1c92"]=1 ["1c94"]=1
        ["1c96"]=1 ["1ca7"]=1 ["1ca8"]=1 ["1caa"]=1 ["1cb1"]=1 ["1cb2"]=1
        ["1cb3"]=1 ["1cb6"]=1 ["1cba"]=1 ["1cbb"]=1 ["1cbc"]=1 ["1cbd"]=1
        ["1ccc"]=1 ["1ccd"]=1 ["1cfa"]=1 ["1cfb"]=1 ["1d01"]=1 ["1d02"]=1
        ["1d10"]=1 ["1d11"]=1 ["1d12"]=1 ["1d13"]=1 ["1d16"]=1 ["1d33"]=1
        ["1d34"]=1 ["1d52"]=1 ["1d56"]=1 ["1d81"]=1 ["1d83"]=1 ["1d84"]=1
        ["1db0"]=1 ["1db1"]=1 ["1db2"]=1 ["1db3"]=1 ["1db4"]=1 ["1db5"]=1
        ["1db6"]=1 ["1db7"]=1 ["1db8"]=1 ["1dba"]=1 ["1dbd"]=1 ["1dbe"]=1
        ["1dc1"]=1 ["1df0"]=1 ["1df2"]=1 ["1df4"]=1 ["1df5"]=1 ["1df6"]=1
)
override_url=""
override_transport=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        blossomos.oci_url=*) override_url="${arg#blossomos.oci_url=}" ;;
        blossomos.oci_transport=*) override_transport="${arg#blossomos.oci_transport=}" ;;
    esac
done

if [[ -n "$override_url" ]]; then
    final_image_ref="$override_url"
else
    suffix=""
    for id in $(lspci -d 10de: -n 2>/dev/null | awk '{print $3}' | cut -d: -f2); do
        id="${id,,}"
        if [[ -n "${blossomos_legacy_nvidia[$id]:-}" ]]; then
            suffix="-nvidia-legacy"
            break
        elif [[ -z "$suffix" ]]; then
            suffix="-nvidia"
        fi
    done
    final_image_ref="__BASE_IMAGE_REF__${suffix}"
fi
final_transport="${override_transport:-registry}"

sed -i \
    -e "s|__BLOSSOMOS_IMAGE_REF__|${final_image_ref}|" \
    -e "s|__BLOSSOMOS_TRANSPORT__|${final_transport}|" \
    /usr/share/anaconda/interactive-defaults.ks \
    /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
PREEOF
    chmod +x /usr/libexec/anaconda/blossomos-resolve-flavor
    sed -i "s|__BASE_IMAGE_REF__|registry.blossomos.org/blossom/image:$IMAGE_TAG|" /usr/libexec/anaconda/blossomos-resolve-flavor

    tee /usr/lib/systemd/system/blossomos-resolve-flavor.service <<'EOF'
[Unit]
Description=Resolve the BlossomOS netinstall image reference (detected hardware or blossomos.oci_url= override)
Requires=basic.target
After=basic.target
Before=anaconda.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/anaconda/blossomos-resolve-flavor
RemainAfterExit=yes
EOF

    mkdir -p /usr/lib/systemd/system/anaconda.target.d
    tee /usr/lib/systemd/system/anaconda.target.d/blossomos-resolve-flavor.conf <<'EOF'
[Unit]
Wants=blossomos-resolve-flavor.service
EOF
fi

tee -a /usr/share/anaconda/interactive-defaults.ks <<EOF
%pre-install
mkdir -p /mnt/sysimage/.ostree-staging
mount --bind /mnt/sysimage/.ostree-staging /var/tmp
%end

$OSTREE_DIRECTIVE
bootloader --append="quiet splash"
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/configure-grub.ks
%include /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks
EOF

if [[ "$NETINSTALL" == "1" ]]; then
    # __BLOSSOMOS_IMAGE_REF__ and __BLOSSOMOS_TRANSPORT__ are resolved by
    # blossomos-resolve-flavor.service before anaconda ever parses this file
    # (see the comment further up).
    tee /usr/share/anaconda/post-scripts/install-configure-upgrade.ks <<'EOF'
%post --erroronfail
bootc switch --mutate-in-place --transport __BLOSSOMOS_TRANSPORT__ __BLOSSOMOS_IMAGE_REF__
%end
EOF
else
    tee /usr/share/anaconda/post-scripts/install-configure-upgrade.ks <<EOF
%post --erroronfail
bootc switch --mutate-in-place --transport registry $IMAGE_REF
%end
EOF
fi

tee /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks <<'EOF'
%post --erroronfail
systemctl disable flatpak-add-fedora-repos.service
%end
EOF

if [[ "$NETINSTALL" == "1" && "$LIVE_SESSION" == "0" ]]; then
    tee /usr/share/anaconda/post-scripts/install-flatpaks.ks <<'EOF'
%post --erroronfail
systemd-tmpfiles --create
flatpak preinstall --system -y --noninteractive
curl -fsSL https://repo.blossomos.org/BLOSSOMOS-GPG-KEY.pub -o /tmp/flatpak-repo-key.asc
flatpak remote-add --system --if-not-exists \
    --gpg-import=/tmp/flatpak-repo-key.asc \
    blossomos https://forge.arcstore.net/flatpak
rm -f /tmp/flatpak-repo-key.asc
flatpak update -y
flatpak update --appstream
sync
sleep 3
flatpak install --system -y --noninteractive blossomos \
    org.freedesktop.Platform.Icontheme.BlossomUI \
    org.gtk.Gtk3theme.BlossomUI \
    org.kde.KStyle.BlossomUI//5.15-24.08 \
    org.kde.KStyle.BlossomUI//6.9 \
    org.kde.KStyle.BlossomUI//6.10 \
    org.kde.KStyle.BlossomUI//6.11
flatpak install blossomos net.imput.helium -y --noninteractive
sync
%end
EOF
else
    tee /usr/share/anaconda/post-scripts/install-flatpaks.ks <<'EOF'
%post --erroronfail --nochroot
deployment="$(ostree rev-parse --repo=/mnt/sysimage/ostree/repo ostree/0/1/0)"
target="/mnt/sysimage/ostree/deploy/default/deploy/$deployment.0/var/lib/"
mkdir -p "$target"
rsync -aAXUHKP /var/lib/flatpak_original/ "$target/flatpak"
sync
%end
EOF
fi

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

set_grub_default GRUB_ENABLE_BLSCFG true

set_grub_default GRUB_CMDLINE_LINUX_DEFAULT '"quiet splash"'
set_grub_default GRUB_GFXPAYLOAD_LINUX keep

set_grub_default GRUB_DISABLE_OS_PROBER false

self_dev="$(findmnt -no SOURCE / 2>/dev/null || true)"
self_dev="${self_dev%%[*}"
other_os="$(os-prober 2>/dev/null || true)"
if [[ -n "$self_dev" && -n "$other_os" ]]; then
    other_os="$(grep -v "^${self_dev}:" <<<"$other_os" || true)"
fi

if [[ -n "$other_os" ]]; then
    echo "Other operating systems detected, enabling the GRUB menu:"
    echo "$other_os"
    set_grub_default GRUB_TIMEOUT 5
    set_grub_default GRUB_TIMEOUT_STYLE menu
    for grubenv in /boot/grub2/grubenv /boot/efi/EFI/fedora/grubenv; do
        if [[ -f "$grubenv" ]]; then
            grub2-editenv "$grubenv" unset menu_auto_hide || true
        fi
    done
else
    set_grub_default GRUB_TIMEOUT 0
    set_grub_default GRUB_TIMEOUT_STYLE hidden
fi

grub_cfg="/boot/grub2/grub.cfg"
if [[ ! -f "$grub_cfg" ]]; then
    grub_cfg="/boot/efi/EFI/fedora/grub.cfg"
fi
grub2-mkconfig -o "$grub_cfg" || true
%end
EOF

curl --retry 15 -Lo /etc/sb_pubkey.der "$sbkey"

tee /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks <<'EOF'
%post --erroronfail --nochroot
set -oue pipefail

readonly ENROLLMENT_PASSWORD="blossomos"
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
