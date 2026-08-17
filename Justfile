repo_organization := "blossomos"
images := '(
    [blossomos]=blossomos
)'
flavors := '(
    [main]=main
    [nvidia-open]=nvidia-open
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
    rm -rf output/
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

# Build ISO using Titanoboa
[group('ISO')]
build-iso image="blossomos" tag="main" flavor="main":
    #!/usr/bin/bash
    set -eoux pipefail

    {{ just }} validate "{{ image }}" "{{ tag }}" "{{ flavor }}"

    if [[ "{{ flavor }}" == "main" ]]; then
        iso_name="BlossomOS-$(date +%Y.%m.%d)-x86_64.iso"
        image_tag="{{ tag }}"
    else
        iso_name="BlossomOS-{{ flavor }}-$(date +%Y.%m.%d)-x86_64.iso"
        image_tag="{{ tag }}-nvidia"
    fi

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

    pushd "${titanoboa_dir}"

    ${SUDOIF} env \
        HOOK_post_rootfs="${repo_dir}/iso_files/configure_iso_anaconda.sh" \
        HOOK_pre_initramfs="${repo_dir}/iso_files/pre_initramfs.sh" \
        BLOSSOMOS_IMAGE_TAG="${image_tag}" \
        just build \
        "registry.blossomos.org/blossom/image:${image_tag}" \
        1 \
        "${repo_dir}/flatpaks.list"

    popd

    ${SUDOIF} mv "${titanoboa_dir}/output.iso" "output/${iso_name}"
    ${SUDOIF} chown "$(id -u):$(id -g)" "output/${iso_name}"

    # Generate sha256 checksum and isodata.json
    sha256=$(sha256sum "output/${iso_name}" | awk '{print $1}')
    printf '{\n  "name": "%s",\n  "sha256": "%s"\n}\n' "${iso_name}" "${sha256}" \
        > "output/isodata{{ if flavor == 'main' { '' } else { '-' + flavor } }}.json"

    echo "Built: output/${iso_name}"
    cat "output/isodata{{ if flavor == 'main' { '' } else { '-' + flavor } }}.json"

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
