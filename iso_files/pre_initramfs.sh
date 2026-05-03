#!/usr/bin/env bash
set -xeuo pipefail

if [[ ! -s /etc/dnf/vars/releasever ]] && [[ -f /etc/os-release ]]; then
    source /etc/os-release
    mkdir -p /etc/dnf/vars
    echo "${VERSION_ID:-}" > /etc/dnf/vars/releasever
fi

RPM_TARGET=/usr/lib/sysimage/rpm

# Stash the clean DB before mounting over the directory.
# Copy only the main file; the WAL written by the post_rootfs DNF session ran
# on fuse-overlayfs and contains torn writes that make SQLite report corruption.
SAVED_DB=""
if [[ -f "${RPM_TARGET}/rpmdb.sqlite" ]]; then
    SAVED_DB=$(mktemp)
    cp "${RPM_TARGET}/rpmdb.sqlite" "${SAVED_DB}"
fi

# Mount a real tmpfs over the RPM DB path and leave it mounted.
# fuse-overlayfs (rootless Podman in CI) does not implement POSIX advisory
# locking (fcntl F_SETLK) for SQLite WAL mode. Every RPM/DNF write that
# happens in this build step — including the initramfs recipe that runs after
# this hook — needs a filesystem where SQLite locking works. The tmpfs stays
# mounted for the lifetime of the build container; the squashfs tool reads
# through it so the DB is included in the final ISO.
mkdir -p "${RPM_TARGET}"
mount -t tmpfs -o size=256m tmpfs "${RPM_TARGET}"

if [[ -n "${SAVED_DB}" ]]; then
    cp "${SAVED_DB}" "${RPM_TARGET}/rpmdb.sqlite"
    rm -f "${SAVED_DB}"
else
    rpm --dbpath "${RPM_TARGET}" --initdb
fi

mkdir -p /var/lib
ln -sfn "${RPM_TARGET}" /var/lib/rpm

if [[ -d /etc/ssl/certs ]] && [[ ! -L /etc/ssl/certs ]]; then
    rm -rf /etc/ssl/certs
fi

mkdir -p /etc/dnf
cat > /etc/dnf/dnf.conf <<EOF
[main]
keepcache=0
EOF

if [[ -f /usr/sbin/restorecon ]] && ! /usr/sbin/restorecon --version >/dev/null 2>&1; then
    mv /usr/sbin/restorecon /usr/sbin/restorecon.bak || true
    printf '#!/bin/bash\nexit 0\n' > /usr/sbin/restorecon
    chmod +x /usr/sbin/restorecon
fi
