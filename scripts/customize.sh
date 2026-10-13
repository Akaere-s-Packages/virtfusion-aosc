#!/bin/bash
# Runs inside the bootstrapped target (arch-chroot), copied in by assemble.sh.
# Required env: DISK (whole-disk block device the image lives on).
set -Eeuo pipefail

: "${DISK:?DISK must point to the image block device}"

echo "==> Configuring system defaults"
ln -sfn ../usr/share/zoneinfo/UTC /etc/localtime

# AOSC OS's cloud-init package installs its helpers in /usr/libexec/cloud-init,
# but cloud-init-generator (ds-identify) and the `aosc` distro (usr_lib_exec)
# look in /usr/lib/cloud-init. Without this, the generator exits 3 and
# cloud-init never runs. Skipped once the package ships /usr/lib/cloud-init.
if [[ ! -e /usr/lib/cloud-init && -x /usr/libexec/cloud-init/ds-identify ]]; then
	ln -s ../libexec/cloud-init /usr/lib/cloud-init
fi
[[ -x /usr/lib/cloud-init/ds-identify ]]

# Cloud-init stages are WantedBy=cloud-init.target, which cloud-init-generator
# activates at boot when ds-identify finds a datasource.
systemctl enable \
	cloud-init-main.service cloud-init-local.service cloud-init-network.service \
	cloud-config.service cloud-final.service \
	NetworkManager.service sshd.service systemd-timesyncd.service
# Desktop/hardware services enabled by the AOSC OS base presets; useless on a VPS.
systemctl disable ModemManager.service bluetooth.service gpm.service
# qemu-guest-agent is started by its udev rule when the virtio channel exists.

echo "==> Configuring GRUB"
cat >>/etc/default/grub <<'EOF'

# --- AOSC OS cloud image overrides ---
# Serial console for logs/emergency access; tty0 last so it is /dev/console (VNC).
GRUB_DEFAULT=0
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 console=tty0"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
EOF

echo "==> Generating initramfs"
update-initramfs
ls /boot/initramfs-*.img >/dev/null

echo "==> Installing GRUB (BIOS + UEFI removable path)"
grub-install --target=i386-pc "$DISK"
grub-install --target=x86_64-efi --efi-directory=/efi --removable --no-nvram
grub-mkconfig -o /boot/grub/grub.cfg

echo "==> Generalizing image"
cloud-init clean --logs --seed
rm -f /etc/ssh/ssh_host_*
: >/etc/machine-id
rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/* /var/log/journal/* /var/tmp/* /root/.bash_history
