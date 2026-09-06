# PXE Booting BlossomOS

This document explains how to boot a BlossomOS ISO over the network instead
of writing it to a USB stick or DVD, and how to point an install at a
custom, locally hosted OCI registry instead of `registry.blossomos.org`.

## Before you start: how these ISOs actually boot

BlossomOS ISOs are dracut "live" images (the same mechanism Fedora's own
Workstation Live media uses): a GRUB menu loads `/boot/vmlinuz` and
`/boot/initramfs.img`, the kernel starts with `root=live:CDLABEL=blossomos`,
and dracut's `dmsquash-live` module locates `/LiveOS/squashfs.img` on
whichever local block device carries that label (the DVD or USB drive).

Crucially, **the initramfs on these ISOs has no support built in for
fetching the live root itself over HTTP, NFS, etc.** (it was not built with
dracut's `url-lib` module). This is not a shortcoming to work around by
hand. It means the one thing that reliably works for PXE booting these
particular ISOs, with zero changes to the build, is to make the whole ISO
show up as if it were physically local media. That is what both methods
below do, using [iPXE](https://ipxe.org)'s SAN boot support to fetch the ISO
over HTTP and expose it to the BIOS or UEFI firmware as a virtual optical
drive. Everything past that point boots exactly like a physical install.

Plain TFTP based PXE, without iPXE or HTTP, is not supported: the live root
is multiple GiB, and there is no fetch path for it inside the initramfs.

Two ways to do this, pick one:

- **Method A: sanboot (simplest).** iPXE boots the ISO's own GRUB menu
  unmodified. No extraction needed. You cannot pass extra kernel args this
  way, short of interactively editing the GRUB menu at each machine.
- **Method B: sanhook plus direct kernel boot (full control).** iPXE
  attaches the ISO as a virtual optical drive without booting it, then boots
  the separately hosted `vmlinuz` and `initramfs.img` directly with whatever
  kernel args you want appended. In particular `blossomos.oci_url=`, see
  below.

Use the **netinstall** ISO for PXE (`just build-iso ... live=0 netinstall=1`,
or the `netinstall` flavor from CI). It is the build that does not depend on
flavor: it already probes GPU hardware and fetches the real OS image over
the network at install time, which is exactly the scenario PXE booting is
for.

## 1. Build or fetch an ISO, then stage PXE assets

```bash
just build-iso blossomos main main 0 1   # or grab a released netinstall ISO

just extract-pxe                          # automatically picks the newest output/*.iso
# or explicitly:
just extract-pxe output/BlossomOS-netinstall-2026.08.31-x86_64.iso output/pxe
```

This writes to `output/pxe/` (or your chosen `outdir`):

- `vmlinuz`, `initramfs.img`: extracted straight from the ISO
- `<isoname>.iso` and `<isoname>.iso.sha256`: the ISO itself, hardlinked in
  if possible (falls back to a copy across filesystems)
- `blossomos-sanboot.ipxe`, `blossomos-custom.ipxe`: scripts ready to edit
  for methods A and B, with the ISO filename already filled in

Edit the generated `.ipxe` files if you are not serving them from the same
host as your DHCP `next-server` (they default to iPXE's `${next-server}`
variable).

## 2. Host the files over HTTP

Anything that serves static files works, e.g.:

```bash
cd output/pxe && python3 -m http.server 8080
```

For real use, put this behind a proper web server so it survives reboots.

## 3. Wire up DHCP and TFTP to chainload iPXE

The exact steps depend on your existing PXE and DHCP setup. With `dnsmasq`
as both DHCP and TFTP server, pointing at
[ipxe.efi](https://ipxe.org/download) (UEFI) or `undionly.kpxe` (legacy
BIOS):

```ini
# dnsmasq.conf snippet
enable-tftp
tftp-root=/srv/tftp
dhcp-boot=tag:efi-x86_64,ipxe.efi
dhcp-boot=tag:!efi-x86_64,undionly.kpxe
dhcp-match=set:efi-x86_64,option:client-arch,7
```

Then have the served `ipxe.efi` or `undionly.kpxe` chain into your script,
e.g. by baking the script URL into a `boot.ipxe` at your TFTP or HTTP root:

```
#!ipxe
chain http://<yourserver>:8080/blossomos-sanboot.ipxe
```

(If your PXE environment already runs iPXE, for example netboot.xyz, MAAS,
or a router with iPXE firmware, skip straight to pointing it at one of the
generated `.ipxe` URLs.)

## 4. Boot a machine

Method A (`blossomos-sanboot.ipxe`) drops the client straight into the
ISO's normal GRUB menu, fetched over HTTP as if it were a DVD.

Method B (`blossomos-custom.ipxe`) skips GRUB and boots
`vmlinuz` and `initramfs.img` directly with an explicit `append` line. Edit
this file to add kernel args, most usefully `blossomos.oci_url=` (next
section).

## Custom OCI URLs (`blossomos.oci_url=`)

Netinstall ISOs normally pull the OS image to install from
`registry.blossomos.org/blossom/image:<tag>` (with an `-nvidia` or
`-nvidia-legacy` suffix chosen automatically from the detected GPU). You can
override this at boot with a kernel argument. This is handy for PXE labs
with a small registry mirror running on your own network, custom or
development image builds, or offline installs of an already pulled image:

```
blossomos.oci_url=192.168.1.5:5000/blossom/image:main
```

Optionally also set the transport (defaults to `registry`, i.e. a normal
container registry reachable over the network):

```
blossomos.oci_transport=registry
```

When `blossomos.oci_url=` is present, flavor detection based on the GPU is
skipped entirely. You are naming the exact image to install, so BlossomOS
installs whatever that reference points to, as is.

This only applies to **netinstall** ISOs (`netinstall=1` builds), since
those are the only ones that already fetch the OS image over the network at
install time rather than using one baked into the ISO. Add the argument to
the kernel command line the same way as any other boot arg:

- Method A: press `e` at the ISO's GRUB menu and append it to the `linux`
  line.
- Method B: add it to the `kernel` line in `blossomos-custom.ipxe`, e.g.:

  ```
  kernel http://${next-server}/vmlinuz initrd=initramfs.img root=live:CDLABEL=blossomos enforcing=0 rd.live.image systemd.unit=anaconda.target quiet rhgb blossomos.oci_url=192.168.1.5:5000/blossom/image:main
  ```

The override is applied by a oneshot systemd service
(`blossomos-resolve-flavor.service`) that runs before `anaconda.target`,
reading `/proc/cmdline` and rewriting the install kickstart's
`ostreecontainer` directive accordingly. See the comments around
`OSTREE_DIRECTIVE` in `iso_files/configure_iso_anaconda.sh`.

## Secure Boot

If the target machine has Secure Boot enabled, `ipxe.efi` itself needs to be
signed and trusted (e.g. chained through `shim`) to hand off to the ISO's
own signed `shim` and GRUB. For a quick PXE lab, it is simplest to disable
Secure Boot on the test machine; BlossomOS's installer will offer to enroll
its own key again after a normal install regardless (see the main
[README](README.md#secure-boot)).

## Troubleshooting

- **`sanboot` or `sanhook` fails immediately**: check the HTTP server is
  reachable from the client's network and the `.ipxe` script's URL and path
  are correct. `${next-server}` only resolves to something useful if your
  DHCP config actually sets `next-server` to your HTTP host.
- **GRUB cannot find the live root after sanboot**: this generally means
  the virtual optical drive did not attach correctly; retry with
  `sanboot -k` for verbose iPXE SAN logging.
- **Boots but never finds `CDLABEL=blossomos` (Method B)**: confirm
  `sanhook` (not `sanboot`) succeeded before the `kernel`, `initrd`, and
  `boot` block runs. `sanhook` only *attaches* the drive, it does not boot
  it.
