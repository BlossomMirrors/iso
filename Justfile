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

# Build ISO locally using BlueBuild
[group('ISO')]
build-iso image="blossomos" tag="latest" flavor="main":
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

    if ! command -v bluebuild &>/dev/null; then
        curl -fsSL https://raw.githubusercontent.com/blue-build/cli/main/install.sh | ${SUDOIF} bash
    fi

    ${SUDOIF} bluebuild generate-iso \
        --iso-name "${iso_name}" \
        image "git.blossomos.org/blossom/image:${image_tag}"

    mv "${iso_name}" "output/${iso_name}"

    # Generate sha256 checksum and isodata.json
    sha256=$(sha256sum "output/${iso_name}" | awk '{print $1}')
    printf '{\n  "name": "%s",\n  "sha256": "%s"\n}\n' "${iso_name}" "${sha256}" \
        > "output/isodata{{ if flavor == 'main' { '' } else { '-' + flavor } }}.json"

    echo "Built: output/${iso_name}"
    cat "output/isodata{{ if flavor == 'main' { '' } else { '-' + flavor } }}.json"

# Upload built ISO and isodata.json to BunnyCDN via FTP
# Requires FTP_PASSWORD env var
[group('ISO')]
upload-ftp flavor="main":
    #!/usr/bin/bash
    set -eoux pipefail

    if [[ -z "${FTP_PASSWORD:-}" ]]; then
        echo "ERROR: FTP_PASSWORD is not set"
        exit 1
    fi

    if [[ "{{ flavor }}" == "main" ]]; then
        isodata_file="output/isodata.json"
    else
        isodata_file="output/isodata-{{ flavor }}.json"
    fi

    iso_name=$(jq -r '.name' "${isodata_file}")

    curl -fsST "output/${iso_name}" \
        "ftp://storage.bunnycdn.com/iso/${iso_name}" \
        --user "blossomos:${FTP_PASSWORD}" \
        --ftp-create-dirs

    curl -fsST "${isodata_file}" \
        "ftp://storage.bunnycdn.com/iso/$(basename ${isodata_file})" \
        --user "blossomos:${FTP_PASSWORD}"

    echo "Uploaded ${iso_name} and $(basename ${isodata_file})"

# Generate Flatpak List from the BlossomOS image repo
[group('ISO')]
generate-flatpak-list:
    #!/usr/bin/bash
    set -eoux pipefail
    curl -fsSL "https://git.blossomos.org/Blossom/image/raw/branch/main/build_files/base/packages.flatpak" | \
        grep -v '#' | \
        grep -v '^[[:space:]]*$' | \
        awk '{print $1}' | \
        tee flatpaks.list

# Verify Container with Cosign
[group('Utility')]
verify-container container="" registry="git.blossomos.org/blossom" key="":
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
