#!/usr/bin/env bash
set -xeuo pipefail

# bootc images store the RPM database at /usr/lib/sysimage/rpm.
# /var/lib/rpm is empty after podman export because /var is not populated
# at image build time. Without this symlink, dnf fails with "rpmtsOpenDB failed".

# Always clean /var/lib/rpm unconditionally to remove stale state from prior
# failed runs (a partial Packages.db left here causes "malformed database").
rm -rf /var/lib/rpm
mkdir -p /var/lib

if [[ -d /usr/lib/sysimage/rpm ]] && [[ "$(ls -A /usr/lib/sysimage/rpm 2>/dev/null)" ]]; then
    # Remove lock file and SQLite WAL/SHM journal files left by interrupted
    # transactions; these cause "database disk image is malformed" on open.
    # Modern RPM uses rpmdb.sqlite; older builds used Packages.db — cover both.
    rm -f /usr/lib/sysimage/rpm/.rpm.lock \
          /usr/lib/sysimage/rpm/rpmdb.sqlite-wal \
          /usr/lib/sysimage/rpm/rpmdb.sqlite-shm \
          /usr/lib/sysimage/rpm/Packages.db-wal \
          /usr/lib/sysimage/rpm/Packages.db-shm
    ln -sf /usr/lib/sysimage/rpm /var/lib/rpm
    # Rebuild the SQLite index in case Packages.db itself is stale or corrupt.
    rpm --rebuilddb
fi
