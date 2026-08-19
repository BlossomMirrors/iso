repo_organization := "blossomos"
images := '(
    [blossomos]=blossomos
)'
flavors := '(
    [main]=main
    [nvidia-open]=nvidia-open
    [nvidia-legacy]=nvidia-legacy
)'
tags := '(
    [stable]=stable
    [latest]=latest
    [beta]=beta
    [main]=main
)'
export SUDOIF := if `id -u` == "0" { "" } else { "sudo" }
export PODMAN := if path_exists("/usr/bin/podman") == "true" { env("PODMAN", "/usr/bin/podman") } else if path_exists("/usr/bin/docker") == "true" { env("PODMAN", "docker") } else { env("PODMAN", "exit 1 ; ") }
just := just_executable()

[private]
default:
    @{{ just }} --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	{{ just }} --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    {{ just }} --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	{{ just }} --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    {{ just }} --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    ${SUDOIF} rm -rf output/
    rm -rf vm/
    rm -f *.iso*
    rm -f flatpaks.list

# Check if valid combo
[group('Utility')]
[private]
validate $image $tag $flavor:
    #!/usr/bin/bash
    set -eou pipefail
    declare -A images={{ images }}
    declare -A tags={{ tags }}
    declare -A flavors={{ flavors }}

    # Handle Stable Daily
    if [[ "${tag}" == "stable-daily" ]]; then
        tag="stable"
    fi

    checkimage="${images[${image}]-}"
    checktag="${tags[${tag}]-}"
    checkflavor="${flavors[${flavor}]-}"

    # Validity Checks
    if [[ -z "$checkimage" ]]; then
        echo "Invalid Image..."
        exit 1
    fi
    if [[ -z "$checktag" ]]; then
        echo "Invalid tag..."
        exit 1
    fi
    if [[ -z "$checkflavor" ]]; then
        echo "Invalid flavor..."
        exit 1
    fi

# Image Name
[group('Utility')]
image_name image="blossomos" tag="stable" flavor="main":
    #!/usr/bin/bash
    set -eou pipefail
    {{ just }} validate {{ image }} {{ tag }} {{ flavor }}
    if [[ "{{ flavor }}" =~ main ]]; then
        image_name={{ image }}
    else
        image_name="{{ image }}-{{ flavor }}"
    fi
    echo "${image_name}"

[group('ISO')]
build-iso image="blossomos" tag="main" flavor="main" live="0" netinstall="1":
    #!/usr/bin/bash
    set -eoux pipefail

    {{ just }} validate "{{ image }}" "{{ tag }}" "{{ flavor }}"

    image_tag="{{ tag }}"
    name_suffix=""
    # flavor only picks a target when netinstall=0 (offline, image embedded
    # at build time); netinstall=1 always builds one flavor-independent ISO
    # since the target is decided by hardware detection at install time.
    # name_suffix distinguishes output filenames between the two (also fixes
    # a real collision: an offline flavor=main build and a netinstall build
    # would otherwise both produce BlossomOS-DATE-x86_64.iso/isodata.json).
    if [[ "{{ netinstall }}" == "0" ]]; then
        case "{{ flavor }}" in
            nvidia-open)
                name_suffix="{{ flavor }}"
                image_tag="{{ tag }}-nvidia"
                ;;
            nvidia-legacy)
                name_suffix="{{ flavor }}"
                image_tag="{{ tag }}-nvidia-legacy"
                ;;
        esac
    else
        name_suffix="netinstall"
    fi
    iso_name="BlossomOS-$(date +%Y.%m.%d)-x86_64.iso"
    if [[ -n "$name_suffix" ]]; then
        iso_name="BlossomOS-${name_suffix}-$(date +%Y.%m.%d)-x86_64.iso"
    fi

    # netinstall=1 boots a minimal generic base to render the installer —
    # it never needs GPU-specific drivers, so it doesn't need the full
    # flavor-specific BlossomOS image as its rootfs either.
    rootfs_image="registry.blossomos.org/blossom/image:${image_tag}"
    if [[ "{{ netinstall }}" == "1" ]]; then
        rootfs_image="quay.io/fedora/fedora-bootc:44"
    fi

    ${SUDOIF} rm -rf output
    mkdir -p output

    # Generate flatpak list (Flathub-only; custom-remote packages excluded by generate-flatpak-list)
    {{ just }} generate-flatpak-list

    # Clone or update Titanoboa
    titanoboa_dir="/var/cache/titanoboa"
    if [[ -d "${titanoboa_dir}/.git" ]]; then
        git -C "${titanoboa_dir}" pull --ff-only
    else
        git clone --depth=1 https://dev.blossomos.org/blossom/os/titanoboa.git "${titanoboa_dir}"
    fi

    sed -i 's/label=type:unconfined_t/label=disable/g' "${titanoboa_dir}/Justfile"
    sed -i '/setfiles -F -r/s/$/ || true/' "${titanoboa_dir}/Justfile"
    sed -i '/mv \.\/output\.iso .* &>\/dev\/null/s/$/ || true/' "${titanoboa_dir}/Justfile"
    sed -i 's/ Live ISO//g' "${titanoboa_dir}/src/grub.cfg.tmpl"
    sed -i 's/systemd-detect-virt -c || true/echo none/g' "${titanoboa_dir}/Justfile"

    # The builder container gets a tmpfs /dev with the host device nodes bind mounted
    # in one by one, so a loop device the kernel allocates mid build never appears
    # inside it and both `mount` calls in the iso recipe fail. Replace them with
    # xorriso extraction and mtools, neither of which needs a loop device.
    sed -i \
        -e 's|mount \$ISOROOT/\.\./efiboot\.img \$EFI_BOOT_MOUNT|xorriso -osirrox on -indev $ISOROOT/../efiboot.img -extract /boot/grub $EFI_BOOT_MOUNT/grub|' \
        -e 's|cp -r \$EFI_BOOT_MOUNT/boot/grub \$ISOROOT/boot/|cp -r $EFI_BOOT_MOUNT/grub $ISOROOT/boot/|' \
        -e '/umount \$EFI_BOOT_MOUNT/d' \
        -e 's|mount \$WORKDIR/efiboot\.img \$EFI_BOOT_PART|mmd -i $WORKDIR/efiboot.img ::/EFI ::/EFI/BOOT|' \
        -e 's|cp -dRvf \$ISOROOT/EFI/BOOT/\. \$EFI_BOOT_PART/EFI/BOOT|mcopy -s -i $WORKDIR/efiboot.img $ISOROOT/EFI/BOOT/* ::/EFI/BOOT/|' \
        -e '/EFI_BOOT_PART=\$(mktemp -d)/d' \
        -e '/mkdir -p \$EFI_BOOT_PART\/EFI\/BOOT/d' \
        -e '/umount \$EFI_BOOT_PART/d' \
        -e 's/xorriso shim dosfstools mtools/xorriso shim dosfstools/' \
        -e 's/xorriso shim dosfstools/xorriso shim dosfstools mtools/' \
        -e '/^        mtools$/d' \
        -e 's/^        dosfstools$/        dosfstools\n        mtools/' \
        "${titanoboa_dir}/Justfile"

    # just 1.57 moved which(), logical operators and list literals from `set unstable`
    # to their own `set lists` gate, which older just versions reject as unknown.
    just_version="$({{ just }} --version | awk '{print $2}')"
    if [[ "$(printf '1.57.0\n%s\n' "${just_version}" | sort -V | head -n1)" == "1.57.0" ]]; then
        grep -q '^set lists' "${titanoboa_dir}/Justfile" \
            || sed -i '/^set unstable/a set lists := true' "${titanoboa_dir}/Justfile"
    fi

    repo_dir="$(pwd)"

    # Stage a locally built anaconda-webui RPM into the titanoboa checkout, which is
    # bind-mounted at /app inside the rootfs chroot — that is the only way the
    # post-rootfs hook can reach a file from the host. Set ANACONDA_WEBUI_RPM to point
    # at one explicitly; otherwise the newest build from a sibling anaconda-webui
    # checkout is used. With neither, the hook installs Fedora's anaconda-webui.
    rm -f "${titanoboa_dir}"/anaconda-webui-*.rpm
    webui_rpm="${ANACONDA_WEBUI_RPM:-$(ls -1t "${repo_dir}"/webui/anaconda-webui-*.rpm 2>/dev/null | head -n1 || true)}"
    if [[ -n "${webui_rpm}" ]]; then
        if [[ ! -f "${webui_rpm}" ]]; then
            echo "ANACONDA_WEBUI_RPM does not exist: ${webui_rpm}" >&2
            exit 1
        fi
        echo "Staging anaconda-webui RPM: ${webui_rpm}"
        cp "${webui_rpm}" "${titanoboa_dir}/"
    fi

    # Marker for the post-rootfs hook: env vars set here don't propagate into
    # the chroot the hook runs in, but this dir is bind-mounted at /app there
    # (same trick as the anaconda-webui RPM staging above).
    rm -f "${titanoboa_dir}/.blossomos-live" "${titanoboa_dir}/.blossomos-netinstall" "${titanoboa_dir}/.blossomos-image-tag" "${titanoboa_dir}/.blossomos-flatpaks-list"
    echo "{{ live }}" > "${titanoboa_dir}/.blossomos-live"
    echo "{{ netinstall }}" > "${titanoboa_dir}/.blossomos-netinstall"
    echo "${image_tag}" > "${titanoboa_dir}/.blossomos-image-tag"
    # rootfs-include-flatpaks is skipped for a non-live netinstall build (see
    # titanoboa), so the hook installs flatpaks itself at install time instead
    # and needs the package list staged the same way as the other markers.
    cp "${repo_dir}/flatpaks.list" "${titanoboa_dir}/.blossomos-flatpaks-list"

    extra_kargs="NONE"
    if [[ "{{ live }}" == "0" ]]; then
        extra_kargs="systemd.unit=anaconda.target"
    fi

    pushd "${titanoboa_dir}"

    ${SUDOIF} env \
        HOOK_post_rootfs="${repo_dir}/iso_files/configure_iso_anaconda.sh" \
        HOOK_pre_initramfs="${repo_dir}/iso_files/pre_initramfs.sh" \
        just build \
        "${rootfs_image}" \
        "{{ live }}" \
        "${repo_dir}/flatpaks.list" \
        "squashfs" \
        "${extra_kargs}" \
        "registry.blossomos.org/blossom/image:${image_tag}" \
        "1" \
        "{{ netinstall }}"

    popd

    ${SUDOIF} mv "${titanoboa_dir}/output.iso" "output/${iso_name}"
    ${SUDOIF} chown "$(id -u):$(id -g)" "output/${iso_name}"

    # Generate sha256 checksum and isodata.json
    isodata_file="output/isodata.json"
    if [[ -n "$name_suffix" ]]; then
        isodata_file="output/isodata-${name_suffix}.json"
    fi
    sha256=$(sha256sum "output/${iso_name}" | awk '{print $1}')
    printf '{\n  "name": "%s",\n  "sha256": "%s"\n}\n' "${iso_name}" "${sha256}" \
        > "${isodata_file}"

    echo "Built: output/${iso_name}"
    cat "${isodata_file}"

# Boot the built ISO in QEMU (UEFI, sound, networking, installable disk)
[group('ISO')]
run-vm iso="" disk="vm/blossomos.qcow2" size="50G" memory="8G" cpus="4":
    #!/usr/bin/bash
    set -eou pipefail

    for cmd in qemu-system-x86_64 qemu-img; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            echo "ERROR: ${cmd} not found, install qemu-system-x86 and qemu-img"
            exit 1
        fi
    done

    iso="{{ iso }}"
    if [[ -z "${iso}" ]]; then
        iso=$(ls -1t output/*.iso 2>/dev/null | head -n1 || true)
    fi
    if [[ -z "${iso}" || ! -f "${iso}" ]]; then
        echo "ERROR: no ISO found, run 'just build-iso' first or pass iso=path/to.iso"
        exit 1
    fi

    ovmf_code=""
    for candidate in \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /usr/share/qemu/ovmf-x86_64-code.bin; do
        if [[ -f "${candidate}" ]]; then
            ovmf_code="${candidate}"
            break
        fi
    done
    if [[ -z "${ovmf_code}" ]]; then
        echo "ERROR: no OVMF firmware found, install edk2-ovmf"
        exit 1
    fi
    ovmf_vars_src="${ovmf_code//OVMF_CODE/OVMF_VARS}"
    ovmf_vars_src="${ovmf_vars_src//ovmf-x86_64-code.bin/ovmf-x86_64-vars.bin}"

    disk="{{ disk }}"
    mkdir -p "$(dirname "${disk}")"
    # qcow2 grows on demand, so {{ size }} is only the maximum the guest sees
    if [[ ! -f "${disk}" ]]; then
        qemu-img create -f qcow2 "${disk}" "{{ size }}"
    fi

    vars="$(dirname "${disk}")/OVMF_VARS.fd"
    if [[ ! -f "${vars}" ]]; then
        cp "${ovmf_vars_src}" "${vars}"
        chmod u+w "${vars}"
    fi

    audiodev="none"
    for backend in pipewire pa alsa sdl; do
        if qemu-system-x86_64 -audiodev help 2>/dev/null | grep -qx "${backend}"; then
            audiodev="${backend}"
            break
        fi
    done

    accel=(-machine "q35,smm=off")
    if [[ -w /dev/kvm ]]; then
        accel+=(-enable-kvm -cpu host)
    else
        echo "NOTICE: /dev/kvm not writable, falling back to TCG emulation"
        accel+=(-cpu max)
    fi

    exec qemu-system-x86_64 \
        "${accel[@]}" \
        -m "{{ memory }}" \
        -smp "{{ cpus }}" \
        -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}" \
        -drive "if=pflash,format=raw,file=${vars}" \
        -drive "file=${disk},if=virtio,format=qcow2,cache=writeback,discard=unmap" \
        -drive "file=${iso},media=cdrom,readonly=on" \
        -boot order=dc,menu=on \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        -audiodev "${audiodev},id=snd0" \
        -device intel-hda \
        -device hda-duplex,audiodev=snd0 \
        -device virtio-vga-gl \
        -display gtk,gl=on,show-cursor=on \
        -device qemu-xhci \
        -device usb-tablet \
        -device virtio-rng-pci \
        -name "BlossomOS $(basename "${iso}")"

# Upload built ISO and isodata.json to Cloudflare R2 (EU) via rclone
# Requires R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT and R2_BUCKET env vars
[group('ISO')]
upload-r2 flavor="main":
    #!/usr/bin/bash
    set -eoux pipefail

    for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: ${var} is not set"
            exit 1
        fi
    done

    if ! command -v rclone >/dev/null 2>&1; then
        ${SUDOIF} dnf install -y rclone
    fi

    if [[ "{{ flavor }}" == "main" ]]; then
        isodata_file="output/isodata.json"
    else
        isodata_file="output/isodata-{{ flavor }}.json"
    fi

    iso_name=$(jq -r '.name' "${isodata_file}")

    export RCLONE_CONFIG_R2_TYPE=s3
    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
    export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"
    export RCLONE_CONFIG_R2_REGION=auto
    export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

    rclone copyto "output/${iso_name}" "r2:${R2_BUCKET}/iso/${iso_name}"
    rclone copyto "${isodata_file}" "r2:${R2_BUCKET}/iso/$(basename "${isodata_file}")"

    echo "Uploaded ${iso_name} and $(basename "${isodata_file}") to R2"

# Generate Flatpak List from the BlossomOS image's packages.flatpak (Flathub-only; custom-remote packages excluded)
[group('ISO')]
generate-flatpak-list:
    #!/usr/bin/bash
    set -eoux pipefail
    curl -fsSL "https://dev.blossomos.org/blossom/os/core/image/-/raw/main/build_files/base/packages.flatpak" | \
        grep -v '^#\|^[[:space:]]*$' | \
        awk 'NF == 1 {print $1}' | \
        tee flatpaks.list

# Verify Container with Cosign
[group('Utility')]
verify-container container="" registry="registry.blossomos.org/blossom" key="":
    #!/usr/bin/bash
    set -eou pipefail

    # Get Cosign if Needed
    if [[ ! $(command -v cosign) ]]; then
        COSIGN_CONTAINER_ID=$(${SUDOIF} ${PODMAN} create cgr.dev/chainguard/cosign:latest bash)
        ${SUDOIF} ${PODMAN} cp "${COSIGN_CONTAINER_ID}":/usr/bin/cosign /usr/local/bin/cosign
        ${SUDOIF} ${PODMAN} rm -f "${COSIGN_CONTAINER_ID}"
    fi

    # Verify Cosign Image Signatures if needed
    if [[ -n "${COSIGN_CONTAINER_ID:-}" ]]; then
        if ! cosign verify --certificate-oidc-issuer=https://token.actions.githubusercontent.com --certificate-identity=https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main cgr.dev/chainguard/cosign >/dev/null; then
            echo "NOTICE: Failed to verify cosign image signatures."
            exit 1
        fi
    fi

    # Public Key for Container Verification
    key={{ key }}
    if [[ -z "${key:-}" ]]; then
        key="../image/cosign.pub"
    fi

    # Verify Container using cosign public key
    if ! cosign verify --key "${key}" "{{ registry }}"/"{{ container }}" >/dev/null; then
        echo "NOTICE: Verification failed. Please ensure your public key is correct."
        exit 1
    fi

# Test ISO Configuration Script
[group('ISO')]
test-iso-config:
    #!/usr/bin/bash
    set -eoux pipefail
    bash -n iso_files/configure_iso_anaconda.sh
    echo "ISO configuration script syntax is valid"
