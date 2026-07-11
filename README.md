# RPi Yocto Playground

Learning the Yocto Project hands-on with a Raspberry Pi 5, following
*Mastering Embedded Linux Programming (3rd ed.)* (`Resources/`).

The book uses Yocto 3.1 (Dunfell); this repo uses **Scarthgap (5.0 LTS)**
because it's the LTS release with Raspberry Pi 5 support. Concepts are
identical; syntax differences are noted in `notes/` as they come up.

## Layout

- This repo: configs, custom layers, scripts, notes — the stuff worth tracking.
- `/media/blankmcu/EmbeddedLinux/yocto/`: poky, meta-raspberrypi, downloads,
  sstate-cache, build dirs — the heavy regenerable stuff (~100+ GB).
  That disk is a loop-mounted ext4 image; mount it first with
  `mount_linux_filesystem.sh` from the exFAT drive.

## One-time host setup (new machine)

```bash
./scripts/host-setup.sh   # apt packages + Ubuntu 24.04 AppArmor/userns fix (uses sudo)
```

## Daily workflow

```bash
source scripts/setup-yocto.sh   # checks host & mount, clones if needed, enters build env
bitbake core-image-minimal      # or whatever we're building
```

## Learning roadmap

Phase 1 — First boot (book ch. 6)
- [x] Host setup, clone poky + meta-raspberrypi (scarthgap)
- [x] Build `core-image-minimal` for `raspberrypi5` (2026-07-11, 3729 tasks)
- [x] Flash to SD card (`scripts/flash-sd.sh`), boot, log in — Pi 5 booted 2026-07-11 🎉

Phase 2 — Understand what just happened (ch. 6, 8)
- [ ] Layers, recipes, tasks: read a simple recipe end to end
- [ ] `bitbake -e`, task logs, `oe-pkgdata-util` — inspecting the build
- [ ] Customize the image via local.conf (add packages, ssh)

Phase 3 — Your own layer (ch. 7)
- [ ] Create `meta-playground` with `bitbake-layers create-layer`
- [ ] Write a recipe for a hello-world C program
- [ ] Write a custom image recipe (`playground-image.bb`)
- [ ] devtool workflow: modify a recipe's source, capture as patch

Phase 4 — Below the surface (ch. 3, 4 applied via Yocto)
- [ ] Kernel config tweaks (`bitbake -c menuconfig virtual/kernel`, config fragments)
- [ ] Device tree overlays (blink an LED / read a sensor on GPIO)
- [ ] Add a systemd service to the image

Phase 6 — CAPSTONE: real product on the Pi Zero W
Replace Raspberry Pi OS Lite (~2 min boot) on the deployed USB serial
logger with a purpose-built image (target: boot to working SSH + logging
in ~10-15 s):
- [ ] Second build config: MACHINE=raspberrypi0-wifi (ARMv6)
- [ ] Baseline: measure current Pi OS boot (systemd-analyze blame/critical-chain)
- [ ] Minimal image: busybox + sysvinit + dropbear + wpa_supplicant + WiFi firmware
- [ ] Recipe for the USB serial logger (udev rule + script, ftdi/cp210x/ch341 modules)
- [ ] Measure, then optimize: trim kernel config, quiet boot, static IP option
- [ ] Read-only rootfs so yanking power can't corrupt the SD card

Phase 5 — Real-world skills (ch. 7, 10)
- [ ] Build your own distro conf
- [ ] Package feeds & runtime package management
- [ ] SDK generation (`bitbake -c populate_sdk`) for app development
- [ ] OTA updates (Mender or RAUC layer)

## Notes

Session-by-session journal in `notes/`.
