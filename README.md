# sysinfo-iso

Builds a small bootable amd64 ISO (~93 MB, BIOS + UEFI, also works when written
to a USB stick) that boots straight into a hardware report.

```
./build-iso.sh              # -> sysinfo-amd64.iso
./build-iso.sh ~/out/x.iso  # custom output path
```

Only Docker or Podman is needed on the host. The kernel (Alpine `linux-lts`),
GRUB and userland tools come from Alpine Linux inside a throwaway container.
Set `ALPINE_VERSION` or `CONTAINER=podman` to override the defaults.

The build runs in a temporary `.sysinfo-iso-build.*` folder created next to
the output file and mounted into the container, so the output directory must
be writable and visible to your container runtime. Snap-packaged Docker and
Docker Desktop only share parts of the host (typically `$HOME`, not `/tmp`),
so keep the output somewhere under your home directory with those.

## What it reports

- **CPU**: model, topology, caches, flags, the x86-64 level (v1–v4) with any
  missing flags listed, a plain **AMD64v3 SUPPORTED / NOT SUPPORTED** line,
  virtualization, AES/SHA/AVX-512/AMX, microcode and vulnerabilities
- **System**: vendor/model/serial, board, BIOS version, UEFI vs legacy boot,
  Secure Boot state, TPM
- **Memory**: total, plus each DIMM's slot, size, type, speed, maker and part number
- **GPU**: every display controller with PCI IDs, subsystem and BAR sizes
- **Storage**: disks with model/serial/size/transport, partitions, controllers,
  and SMART health, hours, temperature and wear
- **Network**: NICs with driver, MAC, link speed and supported modes; DHCP is
  tried on every wired port, so IPs and routes are shown too
- **USB** and the full PCI list

## On the booted machine

- tty1 shows a summary and a single-key menu (letters, case-insensitive):
  view the report (`less`), save it to a FAT/exFAT USB stick, run it again,
  open a shell, reboot or power off. The menu is up while the report is still
  being collected; collection output is logged to `$LOG` from
  `/etc/sysinfo.conf` (`/run/sysinfo.log`).
  Saving only offers USB/removable drives, never EFI System Partitions or the
  stick the image booted from, so the machine's own disks are not written to.
- If a tool is missing, the report is still shown but flagged INCOMPLETE (its
  first lines say what is missing). If a run dies before finishing, the
  previous report stays and the menu says the last re-run FAILED; the partial
  output is kept in `/tmp/sysinfo.txt.failed` and can be viewed and saved from
  the menu (`v`/`s` when there is no earlier report, else `o`/`w`). The
  outcome of the latest run and the installed report's quality are in
  `/run/sysinfo.status`; the collection lock is `/run/sysinfo.lock`.
- Devices plugged in after boot (keyboards, USB sticks, USB NICs) get their
  drivers loaded automatically.
- Alt+F2 gives a root shell.
- The report is also written to the serial port (`ttyS0`, 115200), which is
  handy for headless boxes.

## Limitations

- Not signed, so turn off Secure Boot to boot it.
- GPU, sound and Wi-Fi drivers and firmware are left out to keep the image
  small. Those devices are still found through their PCI IDs, but a monitor's
  EDID and Wi-Fi interfaces won't be shown.

## Testing in QEMU

```
qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -cdrom sysinfo-amd64.iso
```

## License

MIT; see [LICENSE](LICENSE). This covers the scripts in this repository.
The built ISO also contains third-party software from Alpine Linux (the Linux
kernel, BusyBox, GRUB and the other packages), which stays under its own
licenses (mostly GPL).
