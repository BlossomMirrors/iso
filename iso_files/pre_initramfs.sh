#!/usr/bin/env bash
set -xeuo pipefail

# bootc images store the RPM database at /usr/lib/sysimage/rpm.
# /var/lib/rpm is empty after podman export because /var is not populated
# at image build time. Without this symlink, dnf fails with "rpmtsOpenDB failed".

# Ensure $releasever resolves for DNF. On bootc images /etc/dnf/vars/releasever
# may be absent, and a freshly rebuilt RPMDB can't provide it via fedora-release.
if [[ ! -s /etc/dnf/vars/releasever ]] && [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ -n "${VERSION_ID:-}" ]]; then
        mkdir -p /etc/dnf/vars
        echo "$VERSION_ID" > /etc/dnf/vars/releasever
    fi
fi

rm -rf /var/lib/rpm
mkdir -p /var/lib

if [[ -d /usr/lib/sysimage/rpm ]] && [[ "$(ls -A /usr/lib/sysimage/rpm 2>/dev/null)" ]]; then
    # Clear stale lock and WAL/SHM files before rebuilding.
    # Modern RPM uses rpmdb.sqlite; older builds used Packages.db.
    rm -f /usr/lib/sysimage/rpm/.rpm.lock \
          /usr/lib/sysimage/rpm/rpmdb.sqlite-wal \
          /usr/lib/sysimage/rpm/rpmdb.sqlite-shm \
          /usr/lib/sysimage/rpm/Packages.db-wal \
          /usr/lib/sysimage/rpm/Packages.db-shm
    ln -sf /usr/lib/sysimage/rpm /var/lib/rpm
    # rpm --rebuilddb cannot atomically rename in this overlay fs; it writes
    # the rebuilt DB to a sibling rpmrebuilddb.* temp dir instead. Copy it back
    # manually. If rebuilddb exits non-zero (e.g. overlay rename failure), the
    # rpmrebuilddb.* dir may still exist with a valid DB — copy it if present.
    # Never clear the original DB: doing so loses package registrations (e.g.
    # kernel-core) that Titanoboa queries after the initramfs packages install.
    rpm --rebuilddb 2>/dev/null || true
    REBUILD_DIR=$(ls -d /usr/lib/sysimage/rpmrebuilddb.* 2>/dev/null | sort -t. -k2 -n | tail -1) || true
    if [[ -n "${REBUILD_DIR}" ]]; then
        cp -f "${REBUILD_DIR}/rpmdb.sqlite" /usr/lib/sysimage/rpm/rpmdb.sqlite
        rm -rf "${REBUILD_DIR}"
    fi
    rm -f /usr/lib/sysimage/rpm/rpmdb.sqlite-wal \
          /usr/lib/sysimage/rpm/rpmdb.sqlite-shm
fi

# The blossomos image ships /etc/ssl/certs as a real directory, but the fc43
# ca-certificates package installs it as a symlink to /etc/pki/tls/certs.
# RPM cannot replace a directory with a symlink, causing the transaction to fail.
# configure_iso_anaconda.sh has already run its curl calls, so it is safe to
# remove the directory here; ca-certificates will recreate the correct symlink.
if [[ -d /etc/ssl/certs ]] && [[ ! -L /etc/ssl/certs ]]; then
    rm -rf /etc/ssl/certs
fi

# When building fc43 packages on an fc44 host, two scriptlet failures occur:
# 1. The host's restorecon requires LIBSELINUX_3.10 which fc43 doesn't provide.
# 2. The fc43 filesystem %posttrans Lua script uses an rpm.glob() return value
#    that fc44's RPM Lua API changed from a table to a string, breaking ipairs().
# Skip scriptlets during the initramfs package install to avoid both issues.
# (Scriptlets are not needed for dracut/initramfs-only package chroots.)
if [[ -f /etc/dnf/dnf.conf ]]; then
    if ! grep -q '^tsflags' /etc/dnf/dnf.conf; then
        echo 'tsflags=noscripts' >> /etc/dnf/dnf.conf
    fi
else
    mkdir -p /etc/dnf
    printf '[main]\ntsflags=noscripts\n' > /etc/dnf/dnf.conf
fi

# Belt-and-suspenders: if restorecon is still broken (wrong libselinux version),
# replace it with a no-op so any remaining scriptlets don't fail on it.
if [[ -f /usr/sbin/restorecon ]] && ! /usr/sbin/restorecon --version > /dev/null 2>&1; then
    printf '#!/bin/bash\nexit 0\n' > /usr/sbin/restorecon
    chmod 755 /usr/sbin/restorecon
fi
