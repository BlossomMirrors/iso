#!/usr/bin/env bash
set -xeuo pipefail

if [[ ! -s /etc/dnf/vars/releasever ]] && [[ -f /etc/os-release ]]; then
    source /etc/os-release
    mkdir -p /etc/dnf/vars
    echo "${VERSION_ID:-}" > /etc/dnf/vars/releasever
fi

RPM_TARGET=/usr/lib/sysimage/rpm
mkdir -p "${RPM_TARGET}"

# The pre_initramfs hook and the initramfs step run in separate Podman
# containers. A tmpfs mount in this container is invisible to the next one;
# only overlayfs writes persist across the container boundary.
#
# Strategy: do all SQLite work on a tmpfs (where WAL locking works), then
# copy just the main DB file back to the overlayfs. The file on overlayfs is
# already in WAL mode per its header, so the initramfs container's RPM/DNF
# hits PRAGMA journal_mode=WAL as a no-op — no exclusive lock is acquired on
# a new file, which is the specific operation fuse-overlayfs fails at.
TMP_RPMDB=$(mktemp -d)
mount -t tmpfs -o size=256m tmpfs "${TMP_RPMDB}"

if [[ -f "${RPM_TARGET}/rpmdb.sqlite" ]]; then
    cp "${RPM_TARGET}/rpmdb.sqlite" "${TMP_RPMDB}/"
    rpm --dbpath "${TMP_RPMDB}" -qa >/dev/null 2>&1 || {
        rm -f "${TMP_RPMDB}/rpmdb.sqlite"
        rpm --dbpath "${TMP_RPMDB}" --initdb
    }
else
    rpm --dbpath "${TMP_RPMDB}" --initdb
fi

cp "${TMP_RPMDB}/rpmdb.sqlite" "${RPM_TARGET}/rpmdb.sqlite"
rm -f "${RPM_TARGET}/rpmdb.sqlite-wal" "${RPM_TARGET}/rpmdb.sqlite-shm"
umount "${TMP_RPMDB}"
rmdir "${TMP_RPMDB}"

mkdir -p /var/lib
ln -sfn "${RPM_TARGET}" /var/lib/rpm

if [[ -d /etc/ssl/certs ]] && [[ ! -L /etc/ssl/certs ]]; then
    rm -rf /etc/ssl/certs
fi

mkdir -p /etc/dnf
cat > /etc/dnf/dnf.conf <<EOF
[main]
keepcache=0
# Skip scriptlets that may fail due to library version mismatches during build
tsflags=nodocs
EOF

# Create restorecon stub BEFORE any package installation to prevent
# LIBSELINUX version mismatch errors during filesystem package scriptlets
mkdir -p /usr/sbin
printf '#!/bin/bash\n# Stub to prevent restorecon failures during package installation\n# See: https://github.com/blossomos/iso/issues/restorecon-libselinux-mismatch\nexit 0\n' > /usr/sbin/restorecon
chmod +x /usr/sbin/restorecon

# Also stub restorecon in common locations where RPM scriptlets may look for it
mkdir -p /usr/bin
if [[ ! -f /usr/bin/restorecon ]]; then
    ln -sf /usr/sbin/restorecon /usr/bin/restorecon
fi

# Prevent restorecon calls in RPM scriptlets from failing
mkdir -p /usr/libexec
printf '#!/bin/bash\nexit 0\n' > /usr/libexec/restorecon-helper
chmod +x /usr/libexec/restorecon-helper

# If a real restorecon exists (from a previous package), back it up
if [[ -f /usr/sbin/restorecon.bak ]] || [[ -x /usr/sbin/restorecon.real ]]; then
    : # Already backed up
elif [[ -f /usr/sbin/restorecon ]] && ! grep -q '#!/bin/bash' /usr/sbin/restorecon 2>/dev/null; then
    mv /usr/sbin/restorecon /usr/sbin/restorecon.bak || true
fi
