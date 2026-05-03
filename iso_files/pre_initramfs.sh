#!/usr/bin/env bash
set -xeuo pipefail

if [[ ! -s /etc/dnf/vars/releasever ]] && [[ -f /etc/os-release ]]; then
    source /etc/os-release
    mkdir -p /etc/dnf/vars
    echo "${VERSION_ID:-}" > /etc/dnf/vars/releasever
fi

# DON'T try to repair export-broken DB, just reset it cleanly
if [[ -d /usr/lib/sysimage/rpm ]]; then
    rm -rf /usr/lib/sysimage/rpm
fi

mkdir -p /usr/lib/sysimage/rpm
rpm --initdb

ln -sfn /usr/lib/sysimage/rpm /var/lib/rpm

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

rm -f /usr/share/rpm/rpmdb.sqlite-wal /usr/share/rpm/rpmdb.sqlite-shm

rpm --rebuilddb || true

REBUILD_DIR=$(ls -d /usr/share/rpmrebuilddb.* 2>/dev/null | sort -t. -k2 -n | tail -1 || true)

if [[ -f "${REBUILD_DIR}/rpmdb.sqlite" ]]; then
    # sanity check before overwrite
    sqlite3 "${REBUILD_DIR}/rpmdb.sqlite" "PRAGMA integrity_check;" | grep -q ok

    cp -f "${REBUILD_DIR}/rpmdb.sqlite" /usr/share/rpm/rpmdb.sqlite
    rm -rf "${REBUILD_DIR}"
fi
