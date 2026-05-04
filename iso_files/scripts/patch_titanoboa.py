#!/usr/bin/env python3
import sys

if len(sys.argv) != 2:
    print(f"Usage: {sys.argv[0]} <path-to-justfile>", file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1]) as f:
    content = f.read()

old = (
    "    CMD='set -xeuo pipefail\n"
    "    mkdir -p /var/lib/containers/storage\n"
    "    podman pull {{ container_image || image }}\n"
    "    dnf install -y fuse-overlayfs'\n"
    '    chroot "$CMD"'
)
new = (
    "    mkdir -p {{ rootfs }}/var/lib/containers/storage\n"
    "    {{ PODMAN }} pull --root {{ rootfs }}/var/lib/containers/storage {{ container_image || image }}\n"
    "    CMD='set -xeuo pipefail\n"
    "    dnf install -y fuse-overlayfs'\n"
    '    chroot "$CMD"'
)

patched = content.replace(old, new)
if patched == content:
    print(
        "WARNING: rootfs-include-container pattern not found. Titanoboa may have changed upstream.",
        file=sys.stderr,
    )
else:
    with open(sys.argv[1], "w") as f:
        f.write(patched)
