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

### The build disk

Yocto refuses to build on exFAT/NTFS/tmpfs — it needs a POSIX filesystem
(hardlinks, xattrs, case sensitivity). Our big external drive is exFAT, so
the builds live inside a 250 GB **ext4 image file** on that drive,
loop-mounted at `/media/blankmcu/EmbeddedLinux`:

```bash
./scripts/mount-build-disk.sh create 250   # one-time: create + format the image
./scripts/mount-build-disk.sh              # every session: mount it
```

(The image predates this repo — it was originally made the same way the
create command does it: zero-filled file + `mkfs.ext4` on it, no partition
table. The script is the reproducible replacement for that manual step.)

## One-time host setup (new machine)

```bash
./scripts/host-setup.sh   # apt packages + Ubuntu 24.04 AppArmor/userns fix (uses sudo)
```

## Connecting to the Pi (no router needed)

Direct ethernet cable PC ↔ Pi. The PC shares its WiFi internet over the
wired port via a NetworkManager connection created once with:

```bash
nmcli connection add type ethernet ifname enp6s0 con-name pi-share \
    ipv4.method shared connection.autoconnect yes
```

PC becomes 10.42.0.1 + DHCP server + NAT gateway; the Pi gets an address
on boot. Find it with `ip neigh show dev enp6s0`, then `ssh root@<ip>`.

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
- [x] Layers, recipes, tasks: read a simple recipe end to end (dropbear, notes/05)
- [x] `bitbake -e`, task logs, `oe-pkgdata-util` — inspecting the build (2026-07-12)
- [x] Customize the image via local.conf (dropbear ssh, os-release, cmdline) — ssh'd in 2026-07-11

Phase 3 — Your own layer (ch. 7)
- [x] Create `meta-playground` with `bitbake-layers create-layer` (2026-07-12)
- [x] Write a recipe for a hello-world C program (`recipes-apps/hello`)
- [x] Write a custom image recipe (`playground-image.bb`) — built, 37 pkgs
- [x] devtool workflow: modify a recipe's source, capture as patch (2026-07-12) — **Phase 3 complete**

Phase 4 — Below the surface (ch. 3, 4 applied via Yocto)
- [x] Kernel config tweaks (`bitbake -c menuconfig virtual/kernel`, config fragments) — /proc/config.gz live 2026-07-14
- [x] Device tree overlays — dtparam heartbeat (notes/10) + custom playground-led overlay on GPIO17, LED blinking on target 2026-07-18 (notes/11)
- [x] Add a systemd service to the image — INIT_MANAGER flip + playground-pulse unit, verified 2026-07-18 (notes/12) — **Phase 4 complete**

Phase 5 — Real-world skills (ch. 7, 10)
- [ ] Build your own distro conf
- [ ] Package feeds & runtime package management
- [ ] SDK generation (`bitbake -c populate_sdk`) for app development
- [ ] OTA updates (Mender or RAUC layer)

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

## Notes

Session-by-session journal in `notes/`.
