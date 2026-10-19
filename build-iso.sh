#!/bin/sh
# Build a minimal bootable amd64 ISO (BIOS + UEFI) that boots straight into a
# hardware report: CPU (incl. x86-64-v2/v3/v4 level), GPU, memory, disks,
# network, USB and firmware.
#
# Only Docker or Podman is needed on the host; everything else (kernel, GRUB,
# xorriso, ...) is pulled from Alpine Linux inside a throwaway container.
#
# Usage: ./build-iso.sh [output.iso]
#   ALPINE_VERSION=3.22   Alpine release to build from
#   CONTAINER=docker      container runtime (docker or podman)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-"$HERE/sysinfo-amd64.iso"}
ALPINE_VERSION=${ALPINE_VERSION:-3.22}

if [ -z "${CONTAINER:-}" ]; then
	if command -v docker >/dev/null 2>&1; then CONTAINER=docker
	elif command -v podman >/dev/null 2>&1; then CONTAINER=podman
	else echo "error: docker or podman is required" >&2; exit 1
	fi
fi

# ISO volume label; the live system uses it to recognise its own boot stick.
VOLID=SYSINFO

OUT_DIR=$(cd "$(dirname "$OUT")" && pwd)
OUT_NAME=$(basename "$OUT")

# The container writes into a fresh directory next to the output (so it is
# visible to snap Docker and Docker Desktop, which only share parts of the
# host, e.g. $HOME), and only that directory gets SELinux-relabelled (:z).
# Its private (0700) parent keeps other users out, while the directory itself
# is open to whatever uid the container's root maps to (userns-remap,
# rootless). We copy the ISO out ourselves so it is always owned by the
# calling user, then rename it into place so a failed copy never clobbers an
# existing ISO.
STAGE=$(mktemp -d "$OUT_DIR/.sysinfo-iso-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
# dash skips the EXIT trap on signals unless they are trapped too.
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$STAGE/out"
chmod 777 "$STAGE/out"

echo ">> Building $OUT_DIR/$OUT_NAME with Alpine $ALPINE_VERSION ($CONTAINER)"

"$CONTAINER" run --rm --init --platform linux/amd64 \
	-v "$HERE/overlay:/overlay:ro,z" \
	-v "$STAGE/out:/out:z" \
	-e VOLID="$VOLID" \
	"alpine:$ALPINE_VERSION" sh -euc '
	apk add --no-cache grub grub-bios grub-efi xorriso mtools kmod cpio >/dev/null

	ROOT=/work/rootfs ISO=/work/iso K=/work/kernel
	mkdir -p "$ROOT" "$ISO/boot/grub" "$K"

	echo ">> Installing userland into rootfs"
	mkdir -p "$ROOT/etc/apk"
	cp -a /etc/apk/keys "$ROOT/etc/apk/"
	cp /etc/apk/repositories "$ROOT/etc/apk/"
	apk add --root "$ROOT" --initdb --no-cache --quiet \
		alpine-baselayout busybox busybox-binsh kmod \
		lscpu lsblk util-linux-misc blkid \
		pciutils hwdata-pci usbutils hwdata-usb dmidecode \
		ethtool iproute2 smartmontools less ncurses-terminfo-base
	rm -rf "$ROOT/var/cache/apk" "$ROOT/usr/share/man" "$ROOT/usr/share/doc"

	echo ">> Fetching kernel"
	apk update --quiet
	apk fetch --quiet -o /work linux-lts
	set -- /work/linux-lts-*.apk
	[ -f "$1" ] || { echo "error: could not download linux-lts" >&2; exit 1; }
	# apk files are tarballs with extra pax headers that tar warns about.
	tar -xzf "$1" -C "$K" 2>/dev/null || true
	KVER=$(ls "$K/lib/modules" 2>/dev/null | head -1)
	if [ -z "$KVER" ] || [ ! -f "$K/boot/vmlinuz-lts" ]; then
		echo "error: $1 did not contain lib/modules/* and boot/vmlinuz-lts" >&2
		exit 1
	fi
	cp "$K/boot/vmlinuz-lts" "$ISO/boot/vmlinuz"

	# Keep storage/network/USB/platform drivers; drop GPU, sound, media etc.
	# (GPUs are identified via PCI IDs, no driver or firmware needed).
	mkdir -p "$ROOT/lib/modules"
	cp -a "$K/lib/modules/$KVER" "$ROOT/lib/modules/"
	M="$ROOT/lib/modules/$KVER/kernel"
	rm -rf "$M/drivers/gpu" "$M/drivers/media" "$M/sound" \
		"$M/drivers/infiniband" "$M/drivers/staging" "$M/drivers/net/wireless" \
		"$M/drivers/isdn" "$M/drivers/iio" "$M/net/bluetooth" "$M/drivers/bluetooth" \
		"$M/drivers/net/can" "$M/net/mac80211" "$M/net/wireless"
	depmod -b "$ROOT" "$KVER"

	echo ">> Adding overlay"
	cp -a /overlay/. "$ROOT/"
	chmod 755 "$ROOT/init" "$ROOT/usr/local/bin/"*
	echo "VOLID=$VOLID" >> "$ROOT/etc/sysinfo.conf"

	echo ">> Packing initramfs"
	(cd "$ROOT" && find . | cpio -o -H newc --quiet | gzip -9) > "$ISO/boot/initramfs.gz"

	cat > "$ISO/boot/grub/grub.cfg" <<EOF
if serial --unit=0 --speed=115200; then
	terminal_input console serial
	terminal_output console serial
fi
set timeout=3
set default=0

menuentry "System Info" {
	linux /boot/vmlinuz quiet loglevel=3 console=ttyS0,115200 console=tty0
	initrd /boot/initramfs.gz
}
menuentry "System Info (verbose kernel log)" {
	linux /boot/vmlinuz console=ttyS0,115200 console=tty0
	initrd /boot/initramfs.gz
}
menuentry "System Info (safe graphics: nomodeset)" {
	linux /boot/vmlinuz quiet loglevel=3 nomodeset console=ttyS0,115200 console=tty0
	initrd /boot/initramfs.gz
}
EOF

	echo ">> Creating hybrid BIOS/UEFI ISO"
	grub-mkrescue -o /out/sysinfo.iso "$ISO" -- -volid "$VOLID" >/work/xorriso.log 2>&1 ||
		{ cat /work/xorriso.log; exit 1; }
	test -s /out/sysinfo.iso
	echo ">> Kernel $KVER, initramfs $(du -h "$ISO/boot/initramfs.gz" | cut -f1)"
'

cp "$STAGE/out/sysinfo.iso" "$STAGE/sysinfo.iso"
mv -f "$STAGE/sysinfo.iso" "$OUT_DIR/$OUT_NAME"
echo ">> Done: $OUT_DIR/$OUT_NAME ($(du -h "$OUT_DIR/$OUT_NAME" | cut -f1))"
echo "   Write to USB:  sudo dd if=$OUT_DIR/$OUT_NAME of=/dev/sdX bs=4M conv=fsync"
