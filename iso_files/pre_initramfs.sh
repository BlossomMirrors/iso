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
    cp "${RPM_TARGET}/rpmdb.sqlite"* "${TMP_RPMDB}/"
    rpm --dbpath "${TMP_RPMDB}" -qa >/tmp/rpm_qa_error.log 2>&1 || {
        cat /tmp/rpm_qa_error.log
        rm -f "${TMP_RPMDB}/rpmdb.sqlite"*
        rpm --dbpath "${TMP_RPMDB}" --initdb
    }
else
    rpm --dbpath "${TMP_RPMDB}" --initdb
fi

cp "${TMP_RPMDB}/rpmdb.sqlite"* "${RPM_TARGET}/"
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
# Skip docs to reduce image size
# Skip broken scriptlets (e.g., filesystem-3.18-50.fc43 Lua bug)
tsflags=nodocs,noscripts
EOF

# Create wrapper script to run essential post-install tasks that noscripts skips
# Handle case where /usr/local exists but is not a directory
# This can happen in some container base images as a placeholder file or symlink
# Use stat instead of -e test for more reliable detection in overlayfs/container environments
if stat /usr/local >/dev/null 2>&1 && [[ ! -d /usr/local ]]; then
    file_type=$(stat -c %F /usr/local 2>/dev/null || echo "unknown")
    echo "WARNING: /usr/local exists but is not a directory (type: ${file_type})"
    if [[ -L /usr/local ]]; then
        # It's a symbolic link - check where it points
        link_target=$(readlink /usr/local)
        echo "WARNING: /usr/local is a symlink pointing to: ${link_target}"
        # Back up the symlink info before removing
        echo "${link_target}" > /usr/local.symlink.bak
        rm -f /usr/local
        echo "WARNING: Removed symlink, will create /usr/local as directory"
    elif [[ -f /usr/local ]]; then
        if [[ -s /usr/local ]]; then
            # Non-empty file - back it up before removing
            echo "WARNING: /usr/local is a non-empty file, backing up to /usr/local.bak"
            cp /usr/local /usr/local.bak
        else
            # Empty file - safe to remove, but still back up for debugging
            echo "WARNING: /usr/local is an empty placeholder file, backing up and removing"
            cp /usr/local /usr/local.bak
        fi
        rm -f /usr/local
    else
        echo "ERROR: /usr/local exists as an unexpected type (${file_type}), cannot proceed safely"
        exit 1
    fi
fi
mkdir -p /usr/local/bin
cat > /usr/local/bin/run-essential-post-scripts <<'EOF'
#!/bin/bash
# Run essential post-install tasks that are normally handled by RPM scriptlets
# This is needed because tsflags=noscripts skips all scriptlets

set -e

# Filesystem package post-install tasks (normally in %post)
# Create standard directory structure if missing
for dir in /home /var /var/lib /var/log /var/tmp /opt /srv /usr/local; do
    mkdir -p "$dir" 2>/dev/null || true
done

# Kernel package post-install tasks (normally in %post)
# Create initramfs and update bootloader entries
if [[ -d /boot ]]; then
    # Mark kernel packages for initramfs regeneration
    touch /boot/.need-initramfs-regen 2>/dev/null || true
fi

echo "Essential post-install tasks completed"
EOF
chmod +x /usr/local/bin/run-essential-post-scripts

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
