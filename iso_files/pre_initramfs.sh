#!/usr/bin/env bash
set -xeuo pipefail

# bootc images store the RPM database at /usr/lib/sysimage/rpm.
# /var/lib/rpm is empty after podman export because /var is not populated
# at image build time. Without this symlink, dnf fails with "rpmtsOpenDB failed".

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
    # rpm --rebuilddb cannot atomically rename in this overlay fs; it instead
    # writes the rebuilt DB to a sibling rpmrebuilddb.* temp dir. Copy it back
    # manually — same pattern used in the image build scripts.
    rpm --rebuilddb 2>/dev/null || true
    REBUILD_DIR=$(ls -d /usr/lib/sysimage/rpmrebuilddb.* 2>/dev/null | sort -t. -k2 -n | tail -1)
    if [[ -n "${REBUILD_DIR}" ]]; then
        cp -f "${REBUILD_DIR}/rpmdb.sqlite" /usr/lib/sysimage/rpm/rpmdb.sqlite
        rm -rf "${REBUILD_DIR}"
    fi
    rm -f /usr/lib/sysimage/rpm/rpmdb.sqlite-wal \
          /usr/lib/sysimage/rpm/rpmdb.sqlite-shm
fi
