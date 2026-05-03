#!/usr/bin/env bash
set -xeuo pipefail

if [[ ! -s /etc/dnf/vars/releasever ]] && [[ -f /etc/os-release ]]; then
    source /etc/os-release
    mkdir -p /etc/dnf/vars
    echo "${VERSION_ID:-}" > /etc/dnf/vars/releasever
fi

RPM_TARGET=/usr/lib/sysimage/rpm

# SQLite WAL mode requires POSIX advisory locking (fcntl F_SETLK). Rootless
# Podman uses fuse-overlayfs, which does not implement these locks reliably for
# newly created files. Initializing or rebuilding on a real tmpfs guarantees
# correct locking semantics; the clean result is then copied to the overlayfs
# target. This also fixes the cross-directory rename failure (EXDEV) that makes
# rpm --rebuilddb exit non-zero when run directly on overlayfs.
TMP_RPMDB=$(mktemp -d)
mount -t tmpfs -o size=256m tmpfs "${TMP_RPMDB}"

if [[ -f "${RPM_TARGET}/rpmdb.sqlite" ]]; then
    cp -a "${RPM_TARGET}/." "${TMP_RPMDB}/"
    rpm --dbpath "${TMP_RPMDB}" --rebuilddb
else
    rpm --dbpath "${TMP_RPMDB}" --initdb
fi

rm -f "${TMP_RPMDB}/rpmdb.sqlite-wal" "${TMP_RPMDB}/rpmdb.sqlite-shm"

rm -rf "${RPM_TARGET}"
mkdir -p "${RPM_TARGET}"
cp -a "${TMP_RPMDB}/." "${RPM_TARGET}/"
umount "${TMP_RPMDB}"
rmdir "${TMP_RPMDB}"

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
