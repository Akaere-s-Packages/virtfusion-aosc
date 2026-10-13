#!/usr/bin/env bash
# Boot the image in QEMU with a VirtFusion-like NoCloud seed (static IP, root
# SSH key, root password, guest agent channel, enlarged disk) and verify the
# provisioning result over SSH.
#
# Usage: test/boot-test.sh IMAGE.qcow2 [bios|uefi] [1|2]
#   arg 2: firmware (default bios); arg 3: cloud-init network-config version (default 2)
#   ARTIFACT_DIR=dir: after a pass, save the VGA console screenshot (boot-<firmware>.png),
#   the installed package list (packages.tsv) and system info (system.env) there.
set -Eeuo pipefail

IMAGE=$(realpath "${1:?usage: $0 IMAGE.qcow2 [bios|uefi] [1|2]}")
FIRMWARE=${2:-bios}
NET_VERSION=${3:-2}
: "${BOOT_TIMEOUT:=600}"
: "${SSH_PORT:=2222}"

MAC=52:54:00:12:34:56
HOSTNAME=aosc-ci
: "${ROOT_PASSWORD:=$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d)
qemu_pid=
cleanup() {
	[[ -n $qemu_pid ]] && kill "$qemu_pid" 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT

case $FIRMWARE in
bios) fw_args=() ;;
uefi)
	code=${OVMF_CODE:-} vars=${OVMF_VARS:-}
	for pair in /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd \
		/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd \
		/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd; do
		[[ -z $code && -f ${pair%%:*} && -f ${pair##*:} ]] && code=${pair%%:*} vars=${pair##*:}
	done
	[[ -n $code ]] || die "OVMF firmware not found; set OVMF_CODE and OVMF_VARS"
	cp "$vars" "$tmp/vars.fd"
	fw_args=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$tmp/vars.fd")
	;;
*) die "firmware must be bios or uefi" ;;
esac

log "Preparing NoCloud seed (network-config v$NET_VERSION, firmware $FIRMWARE)"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/id"
mkdir "$tmp/seed"
cat >"$tmp/seed/meta-data" <<EOF
instance-id: ci-$(date +%s)
local-hostname: $HOSTNAME
EOF
cat >"$tmp/seed/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$tmp/id.pub")
chpasswd:
  expire: false
  users:
    - {name: root, password: $ROOT_PASSWORD, type: text}
EOF
if [[ $NET_VERSION == 1 ]]; then
	cat >"$tmp/seed/network-config" <<EOF
version: 1
config:
  - type: physical
    name: eth0
    mac_address: "$MAC"
    subnets:
      - type: static
        address: 10.0.2.15/24
        gateway: 10.0.2.2
        dns_nameservers: [10.0.2.3]
EOF
else
	cat >"$tmp/seed/network-config" <<EOF
version: 2
ethernets:
  eth0:
    match:
      macaddress: "$MAC"
    addresses: [10.0.2.15/24]
    routes:
      - to: default
        via: 10.0.2.2
    nameservers:
      addresses: [10.0.2.3]
EOF
fi
xorriso -as mkisofs -quiet -o "$tmp/seed.iso" -V cidata -J -R "$tmp/seed"

# Overlay so the image stays pristine; 10G larger than the image to exercise growpart/resizefs.
image_bytes=$(qemu-img info --output=json "$IMAGE" | jq '."virtual-size"')
qemu-img create -q -f qcow2 -F qcow2 -b "$IMAGE" "$tmp/disk.qcow2" $((image_bytes + 10 * 1024 ** 3))

accel=tcg
[[ -w /dev/kvm ]] && accel=kvm
log "Booting with $accel acceleration"
qemu-system-x86_64 \
	-machine q35,accel=$accel -cpu max -smp 2 -m 2048 \
	"${fw_args[@]}" \
	-drive "if=virtio,format=qcow2,file=$tmp/disk.qcow2" \
	-drive "media=cdrom,format=raw,readonly=on,file=$tmp/seed.iso" \
	-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
	-device "virtio-net-pci,netdev=n0,mac=$MAC" \
	-device virtio-serial \
	-chardev "socket,id=qga0,path=$tmp/qga.sock,server=on,wait=off" \
	-device "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0" \
	-display none -serial "file:$tmp/serial.log" \
	-monitor "unix:$tmp/monitor.sock,server=on,wait=off" &
qemu_pid=$!

# Run one HMP (human monitor) command and wait for it to complete.
hmp() {
	python3 - "$tmp/monitor.sock" "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
def until_prompt():
    buf = b""
    while not buf.endswith(b"(qemu) "):
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf
until_prompt()
s.sendall(sys.argv[2].encode() + b"\n")
sys.stdout.write(until_prompt().decode(errors="replace").split("\n", 1)[-1].rsplit("(qemu)", 1)[0])
PY
}

ssh_cmd=(ssh -q -i "$tmp/id" -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1)
deadline=$((SECONDS + BOOT_TIMEOUT))
log "Waiting for SSH (timeout ${BOOT_TIMEOUT}s); console log: $tmp/serial.log"
log "Manual login while the VM runs: ssh -i $tmp/id -p $SSH_PORT root@127.0.0.1 (root password: $ROOT_PASSWORD)"
boot_start=$SECONDS next_report=$((SECONDS + 30))
until "${ssh_cmd[@]}" true 2>/dev/null; do
	if ((SECONDS > deadline)) || ! kill -0 "$qemu_pid" 2>/dev/null; then
		cat "$tmp/serial.log" >&2
		die "no SSH access as root within ${BOOT_TIMEOUT}s"
	fi
	sleep 5
	if ((SECONDS >= next_report)); then
		next_report=$((SECONDS + 30))
		last=$(tr -d '\r' <"$tmp/serial.log" | grep -v '^\s*$' | tail -n 1 | cut -c1-120)
		log "still waiting ($((SECONDS - boot_start))s): ${last:-<no console output yet>}"
	fi
done
log "SSH up as root after $((SECONDS - boot_start))s"

guest() { "${ssh_cmd[@]}" "$@"; }

guest cloud-init status --wait --long || {
	guest 'grep -E -A5 "WARNING|ERROR|Traceback" /var/log/cloud-init.log' >&2 || true
	die "cloud-init did not finish cleanly"
}
state=$(guest 'systemctl is-system-running --wait' || true)
[[ $state == running ]] || { guest 'systemctl --failed --no-pager' >&2; die "system state: $state"; }

[[ $(guest hostname) == "$HOSTNAME" ]] || die "hostname not applied"
root_bytes=$(guest 'findmnt -bno SIZE /')
((root_bytes > image_bytes)) || die "root filesystem not grown ($root_bytes bytes)"
guest 'grep -qx "method=manual" /etc/NetworkManager/system-connections/cloud-init-*.nmconnection' ||
	die "static network config not rendered for NetworkManager"
guest 'ip -4 -o addr show' | grep -q ' 10.0.2.15/24 ' || die "static IP not configured"
guest 'getent hosts repo.aosc.io' >/dev/null || die "DNS resolution failed"
[[ $(guest 'passwd -S root' | awk '{print $2}') == P ]] || die "root password not set"
guest 'systemctl is-active qemu-guest-agent' >/dev/null || die "qemu-guest-agent not running"
guest 'ls /sys/firmware/efi' >/dev/null 2>&1 && booted=uefi || booted=bios
[[ $booted == "$FIRMWARE" ]] || die "booted via $booted, expected $FIRMWARE"

guest 'cat /etc/os-release; uname -r; df -h /; cloud-init --version' >&2
log "PASS ($FIRMWARE, network-config v$NET_VERSION)"

if [[ -n ${ARTIFACT_DIR:-} ]]; then
	mkdir -p "$ARTIFACT_DIR"
	ARTIFACT_DIR=$(realpath "$ARTIFACT_DIR")
	guest "dpkg-query -W -f '\${Package}\t\${Version}\n'" | sort >"$ARTIFACT_DIR/packages.tsv"
	guest 'cat /etc/os-release; echo "KERNEL=$(uname -r)"; echo "CLOUD_INIT=$(cloud-init --version 2>&1 | cut -d" " -f2)"' \
		>"$ARTIFACT_DIR/system.env"
	# Draw a summary plus fastfetch on the VGA console (what VirtFusion's VNC shows), then capture it.
	guest "{
		printf '\033[2J\033[H'
		echo '=== AOSC OS cloud image: boot test passed ($FIRMWARE, network-config v$NET_VERSION) ==='
		echo \"Firmware: $FIRMWARE    cloud-init: \$(cloud-init status | cut -d' ' -f2) (\$(cloud-init status --long | sed -n 's/^detail: //p'))\"
		echo
		fastfetch --pipe false
	} >/dev/tty1"
	sleep 1
	shot=$ARTIFACT_DIR/boot-$FIRMWARE.png
	rm -f "$shot"
	# PPM is the one screendump format every QEMU build supports; convert it here
	# instead of relying on QEMU being built with libpng.
	hmp "screendump $tmp/screen.ppm" >&2
	[[ -s $tmp/screen.ppm ]] || die "screendump failed"
	python3 - "$tmp/screen.ppm" "$shot" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
fields, pos = [], 0
while len(fields) < 4:  # P6 header: magic, width, height, maxval (comments allowed)
    while data[pos:pos + 1].isspace():
        pos += 1
    if data[pos:pos + 1] == b"#":
        pos = data.index(b"\n", pos)
        continue
    end = pos
    while not data[end:end + 1].isspace():
        end += 1
    fields.append(data[pos:end])
    pos = end
assert fields[0] == b"P6" and fields[3] == b"255", fields
w, h = int(fields[1]), int(fields[2])
pixels = data[pos + 1:pos + 1 + w * h * 3]
raw = b"".join(b"\0" + pixels[y * w * 3:(y + 1) * w * 3] for y in range(h))
def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
with open(sys.argv[2], "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n")
    f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
    f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
    f.write(chunk(b"IEND", b""))
PY
	[[ -s $shot ]] || die "screenshot not written to $shot"
	log "Saved $shot, packages.tsv and system.env to $ARTIFACT_DIR"
fi

guest 'systemctl poweroff' || true
wait "$qemu_pid" || true
qemu_pid=
