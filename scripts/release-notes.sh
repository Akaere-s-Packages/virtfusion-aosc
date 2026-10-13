#!/usr/bin/env bash
# Render GitHub release notes from boot-test artifacts.
# Usage: release-notes.sh ARTIFACT_DIR IMAGE.qcow2 TAG OWNER/REPO > notes.md
set -Eeuo pipefail

ART=${1:?usage: $0 ARTIFACT_DIR IMAGE.qcow2 TAG OWNER/REPO}
IMAGE=${2:?}
TAG=${3:?}
REPO=${4:?}

sysval() { sed -n "s/^$1=//p" "$ART/system.env" | tr -d '"'; }
asset() { echo "https://github.com/$REPO/releases/download/$TAG/$1"; }

image_name=$(basename "$IMAGE")
pkg_count=$(wc -l <"$ART/packages.tsv")

cat <<EOF
AOSC OS cloud-init image for VirtFusion, built and boot-tested by CI.

| | |
| --- | --- |
| Base | $(sysval PRETTY_NAME) (build $(sysval BUILD_ID)) |
| Kernel | \`$(sysval KERNEL)\` |
| cloud-init | $(sysval CLOUD_INIT) |
| Image | \`$image_name\` ($(du -h "$IMAGE" | cut -f1), qcow2 $(qemu-img info --output=json "$IMAGE" | jq -r '."format-specific".data."compression-type"') compressed, $(qemu-img info --output=json "$IMAGE" | jq '."virtual-size" / 1073741824') GiB virtual) |
| SHA256 | \`$(sha256sum "$IMAGE" | cut -d' ' -f1)\` |

## Boot test

Booted under QEMU with a VirtFusion-like NoCloud seed; cloud-init, static networking,
root filesystem growth, root password, SSH and qemu-guest-agent were verified.

**BIOS, network-config v2**

![BIOS boot]($(asset boot-bios.png))

**UEFI, network-config v1**

![UEFI boot]($(asset boot-uefi.png))

## Installed packages ($pkg_count)

<details>
<summary>Show all package versions</summary>

| Package | Version |
| --- | --- |
EOF
awk -F'\t' '{ printf "| %s | `%s` |\n", $1, $2 }' "$ART/packages.tsv"
cat <<'EOF'

</details>
EOF
