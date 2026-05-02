#!/usr/bin/env bash
set -xeuo pipefail

# bootc images store the RPM database at /usr/lib/sysimage/rpm.
# /var/lib/rpm is empty after podman export because /var is not populated
# at image build time. Without this symlink, dnf fails with "rpmtsOpenDB failed".
if [[ -d /usr/lib/sysimage/rpm ]] && [[ "$(ls -A /usr/lib/sysimage/rpm 2>/dev/null)" ]]; then
    rm -rf /var/lib/rpm
    mkdir -p /var/lib
    ln -sf /usr/lib/sysimage/rpm /var/lib/rpm
fi
