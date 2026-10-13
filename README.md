# AOSC OS cloud-init image for VirtFusion

Builds an [AOSC OS](https://aosc.io/) (amd64, `stable` branch) qcow2 cloud image
with cloud-init, intended as a VirtFusion OS template.

## Image contents

- Minimal AOSC OS system from `aoscbootstrap` with the package list in `packages.lst`
- GPT disk: BIOS boot + 100 MiB ESP + ext4 root (last, so `growpart` can grow it).
  GRUB is installed for both BIOS and UEFI (removable path `EFI/BOOT/BOOTX64.EFI`)
- cloud-init (AOSC `aosc` distro), restricted to the `NoCloud` and `ConfigDrive`
  datasources that VirtFusion uses; network-config v1 and v2 are rendered to NetworkManager
- Root login via SSH with password or key (`disable_root: false`, `ssh_pwauth: true`,
  `PermitRootLogin yes`), plus a locked default user `aosc` with passwordless sudo
- qemu-guest-agent (started automatically when the virtio channel exists)
- Kernel console on `ttyS0` and `tty0`, timezone UTC, generic (non-hostonly) initramfs
- Generalized: empty machine-id, no SSH host keys, clean cloud-init state

## Requirements

A Linux host with root access, loop device support and network access.

| Purpose | Arch Linux | Debian / Ubuntu |
| --- | --- | --- |
| Build | `curl jq xz qemu-img util-linux` | `curl jq xz-utils qemu-utils util-linux` |
| Boot test | `qemu-system-x86 edk2-ovmf libisoburn openssh` | `qemu-system-x86 ovmf xorriso openssh-client` |

All other tools (aoscbootstrap, GRUB, dracut, mkfs) run inside the official
AOSC OS container tarball, which the build downloads and verifies automatically.

## Build

```sh
sudo ./build.sh
```

Output: `output/aosc-os-cloud-amd64.qcow2` and its `.sha256`.

To remove leftovers of an interrupted build, run `sudo ./build.sh --clean`.
This removes the build environment, the raw disk and partial files, and detaches stale loop devices.
It keeps the downloaded tarball cache and finished images.

Environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DISK_SIZE` | `10G` | Virtual disk size, also the minimum VM disk size (cloud-init grows the root partition on first boot) |
| `BRANCH` | `stable` | AOSC OS repository branch |
| `QCOW2_COMPRESSION` | `zstd` | qcow2 cluster compression: `zstd` (needs QEMU >= 5.1 on the hypervisor) or `zlib` (any QEMU) |
| `MIRROR` | (official) | Alternative APT mirror URL for aoscbootstrap |
| `WORK_DIR` | `./work` | Scratch space (needs about 16 GB) |
| `OUT_DIR` | `./output` | Output directory |
| `KEEP_WORK` | `0` | Set to `1` to keep the build environment and raw disk |

## Test

```sh
./test/boot-test.sh output/aosc-os-cloud-amd64.qcow2 bios 2
./test/boot-test.sh output/aosc-os-cloud-amd64.qcow2 uefi 1
```

The test boots the image in QEMU (KVM if available) with a VirtFusion-like
NoCloud seed: static IP, root SSH key and password, guest agent channel and a
disk enlarged by 10G. Over SSH it checks that cloud-init finished cleanly, that the system has no failed units,
and that the hostname, root filesystem growth, static networking, DNS, root password, guest agent
and boot firmware are all as expected.
The arguments are the firmware (`bios` or `uefi`) and the network-config version (`1` or `2`).

## CI

`.github/workflows/build.yml` builds the image and runs both boot tests on every
push, pull request, manual dispatch and weekly. It is test-only: no artifacts,
releases or caches are kept.

## Using it in VirtFusion

1. Copy the qcow2 to your template storage (VirtFusion uses the `.img` extension
   for both raw and qcow2 images).
2. Create an OS template using that image with cloud-init enabled. Both network
   config versions work.
3. Do not boot the image outside VirtFusion before importing it. A boot would
   create a cloud-init instance state, machine-id and SSH host keys.
