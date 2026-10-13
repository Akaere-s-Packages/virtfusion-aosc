#!/bin/bash
# Runs inside the AOSC OS build environment (chroot set up by build.sh).
# Partitions the raw disk, bootstraps AOSC OS into it and installs GRUB.
# Usage: assemble.sh DISK.raw    Env: BRANCH, MIRROR (optional)
set -Eeuo pipefail

RAW=${1:?usage: assemble.sh DISK.raw}
SRC=/srv/src
TARGET=/mnt/target

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

log "Installing aoscbootstrap"
apt-get update -q
apt-get install -y -q aoscbootstrap
# aoscbootstrap runs stage 2 by booting systemd-nspawn when it is available,
# which needs systemd as PID 1. This build environment is a plain chroot, so
# force aoscbootstrap's arch-chroot fallback.
rm -f /usr/bin/systemd-nspawn

loop=$(losetup --find --show --partscan "$RAW")
uuid_link=
cleanup() {
	set +e
	[[ -n $uuid_link ]] && rm -f "$uuid_link"
	mountpoint -q "$TARGET" && umount -R "$TARGET"
	losetup -d "$loop"
}
trap cleanup EXIT

log "Partitioning $loop (GPT: BIOS boot, ESP, root)"
sfdisk --quiet "$loop" <<'EOF'
label: gpt
size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name="BIOS boot"
size=100MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System"
type=0FC63DAF-8483-4772-8E79-3D69C8477DE4, name="AOSC OS"
EOF
for _ in {1..50}; do [[ -b ${loop}p3 ]] && break; sleep 0.2; done
[[ -b ${loop}p3 ]] || die "partition devices for $loop did not appear"

mkfs.vfat -F 32 -n EFI "${loop}p2" >/dev/null
mkfs.ext4 -q -L aosc-root "${loop}p3"
mkdir -p "$TARGET"
mount "${loop}p3" "$TARGET"

log "Bootstrapping AOSC OS ($BRANCH)"
mirror_args=()
[[ -n ${MIRROR:-} ]] && mirror_args=(--mirror "$MIRROR")
aoscbootstrap \
	--target "$TARGET" --force \
	--config /usr/share/aoscbootstrap/config/aosc-mainline.toml \
	--include-files "$SRC/packages.lst" \
	--arch amd64 --branch "$BRANCH" "${mirror_args[@]}" \
	--clean --no-progressbar

mkdir -p "$TARGET/efi"
mount "${loop}p2" "$TARGET/efi"
cp -rT "$SRC/rootfs" "$TARGET"

root_uuid=$(blkid -s UUID -o value "${loop}p3")
esp_uuid=$(blkid -s UUID -o value "${loop}p2")
cat >>"$TARGET/etc/fstab" <<EOF
UUID=$root_uuid	/	ext4	defaults	0	1
UUID=$esp_uuid	/efi	vfat	umask=0077,nofail	0	2
EOF

# grub-mkconfig only emits root=UUID=... if /dev/disk/by-uuid has the link,
# and udev may not have created it for a freshly formatted loop partition.
if [[ ! -e /dev/disk/by-uuid/$root_uuid ]]; then
	mkdir -p /dev/disk/by-uuid
	uuid_link=/dev/disk/by-uuid/$root_uuid
	ln -s "../../${loop#/dev/}p3" "$uuid_link"
fi

log "Customizing target"
# Run from a file, not stdin: commands inside (dracut via parallel, ...) may read stdin.
cp "$SRC/scripts/customize.sh" "$TARGET/root/customize.sh"
arch-chroot "$TARGET" /usr/bin/env DISK="$loop" /bin/bash /root/customize.sh
rm -f "$TARGET/root/customize.sh"

grep -q "root=UUID=$root_uuid" "$TARGET/boot/grub/grub.cfg" ||
	die "grub.cfg does not boot root=UUID=$root_uuid"
[[ -f $TARGET/efi/EFI/BOOT/BOOTX64.EFI ]] || die "UEFI fallback loader missing"

# arch-chroot bind-mounts the host resolv.conf while inside; point it at
# systemd-resolved (fed by NetworkManager) only once we are out.
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"

fstrim "$TARGET/efi" || true
fstrim "$TARGET" || true
df -h "$TARGET"
