#!/usr/bin/env bash
# Build an AOSC OS cloud-init qcow2 image for VirtFusion.
#
# Host side: fetch the official AOSC OS "container" tarball as a throwaway
# build environment, then run scripts/assemble.sh inside it (aoscbootstrap,
# partitioning, GRUB). Everything runs in a private mount namespace, so no
# mounts leak onto the host if the build fails.
set -Eeuo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

: "${WORK_DIR:=$REPO_DIR/work}"
: "${OUT_DIR:=$REPO_DIR/output}"
: "${IMAGE_NAME:=aosc-os-cloud-amd64}"
: "${DISK_SIZE:=10G}"
: "${QCOW2_COMPRESSION:=zstd}" # zstd needs QEMU >= 5.1 wherever the image is opened; zlib for older
: "${BRANCH:=stable}"
: "${MIRROR:=}" # empty: aoscbootstrap's default (official repo.aosc.io)
: "${RELEASES_URL:=https://releases.aosc.io}"
: "${KEEP_WORK:=0}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

BUILDENV=$WORK_DIR/buildenv
IMAGE_DIR=$WORK_DIR/image
CACHE_DIR=$WORK_DIR/cache

usage() { echo "usage: $0 [--clean]" >&2; exit 2; }

# Remove leftovers of an interrupted build. The verified tarball cache and
# finished images in OUT_DIR are kept.
clean() {
	local loop
	if [[ -f $IMAGE_DIR/disk.raw ]]; then
		for loop in $(losetup -nO NAME -j "$IMAGE_DIR/disk.raw"); do
			log "Detaching $loop"
			losetup -d "$loop"
		done
	fi
	if findmnt -rno TARGET | grep -q "^$WORK_DIR/"; then
		die "filesystems are still mounted under $WORK_DIR; unmount them first"
	fi
	log "Removing $BUILDENV, $IMAGE_DIR and partial outputs"
	rm -rf --one-file-system "$BUILDENV" "$IMAGE_DIR"
	rm -f "$OUT_DIR"/*.part "$CACHE_DIR"/*.part
}

do_clean=0
for arg in "$@"; do
	case $arg in
	--clean) do_clean=1 ;;
	*) usage ;;
	esac
done

[[ $EUID -eq 0 ]] || die "must run as root (loop devices, mounts, chroot)"

if ((do_clean)); then
	clean
	log "Clean done"
	exit 0
fi

for cmd in curl jq sha256sum tar xz unshare chroot mount qemu-img; do
	command -v "$cmd" >/dev/null || die "missing host command: $cmd"
done

# Re-exec in a private mount namespace: every mount below vanishes on exit.
if [[ -z ${_AOSC_BUILD_NS:-} ]]; then
	exec unshare --mount --propagation private -- env _AOSC_BUILD_NS=1 "$0" "$@"
fi

mkdir -p "$CACHE_DIR" "$IMAGE_DIR" "$OUT_DIR"

log "Resolving latest AOSC OS container tarball"
manifest=$(curl -fsSL "$RELEASES_URL/manifest/recipe.json")
read -r tar_path tar_sha < <(jq -r '
	[.variants[] | select(.name == "Container") | .tarballs[]
	 | select(.arch == "amd64" and (.path | endswith(".tar.xz")))]
	| max_by(.date) | "\(.path) \(.sha256sum)"' <<<"$manifest")
[[ -n $tar_path && $tar_path != null ]] || die "no amd64 container tarball in release manifest"
tarball=$CACHE_DIR/$(basename "$tar_path")

if ! sha256sum --quiet -c <<<"$tar_sha  $tarball" 2>/dev/null; then
	log "Downloading $tar_path"
	curl -fL --retry 3 -o "$tarball.part" "$RELEASES_URL/$tar_path"
	sha256sum --quiet -c <<<"$tar_sha  $tarball.part" || die "checksum mismatch for $tar_path"
	mv "$tarball.part" "$tarball"
fi

log "Extracting build environment"
rm -rf --one-file-system "$BUILDENV"
mkdir -p "$BUILDENV"
tar --numeric-owner -xpf "$tarball" -C "$BUILDENV"

mount --rbind /dev "$BUILDENV/dev"
mount -t proc proc "$BUILDENV/proc"
mount --rbind /sys "$BUILDENV/sys"
mount -t tmpfs tmpfs "$BUILDENV/run"
mount -t tmpfs tmpfs "$BUILDENV/tmp"
rm -f "$BUILDENV/etc/resolv.conf"
cp -L /etc/resolv.conf "$BUILDENV/etc/resolv.conf"
mkdir -p "$BUILDENV/srv/src" "$BUILDENV/srv/image"
mount --bind -o ro "$REPO_DIR" "$BUILDENV/srv/src"
mount --bind "$IMAGE_DIR" "$BUILDENV/srv/image"

raw=$IMAGE_DIR/disk.raw
rm -f "$raw"
truncate -s "$DISK_SIZE" "$raw"

log "Assembling image inside AOSC OS build environment"
chroot "$BUILDENV" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin \
	HOME=/root TERM="${TERM:-dumb}" LANG=C.UTF-8 \
	BRANCH="$BRANCH" MIRROR="$MIRROR" \
	/bin/bash /srv/src/scripts/assemble.sh /srv/image/disk.raw

log "Converting to compressed qcow2"
qcow2=$OUT_DIR/$IMAGE_NAME.qcow2
# Write to .part first so an interrupted conversion never looks like a finished image.
qemu-img convert -c -O qcow2 -o compression_type="$QCOW2_COMPRESSION" "$raw" "$qcow2.part"
mv "$qcow2.part" "$qcow2"
(cd "$OUT_DIR" && sha256sum "$IMAGE_NAME.qcow2" >"$IMAGE_NAME.qcow2.sha256")

if [[ $KEEP_WORK != 1 ]]; then
	umount -R "$BUILDENV/srv/image" "$BUILDENV/srv/src" "$BUILDENV/tmp" "$BUILDENV/run" \
		"$BUILDENV/sys" "$BUILDENV/proc" "$BUILDENV/dev"
	rm -rf --one-file-system "$BUILDENV" "$raw"
fi

qemu-img info "$qcow2"
log "Done: $qcow2"
