# Session 11 — RAUC A/B OTA updates (part 1: it boots)

Goal: the last Phase 5 item — update the OS in the field without a human
holding an SD card, and survive a bad update.

Status: **PARTIAL.** The A/B boot chain is VERIFIED on target 2026-08-09.
Building and installing an actual bundle is still to do, so the README
checkbox stays unticked. Most of this session went into a boot failure
that we ultimately could not reproduce — the write-up of that is the
second half of this file, and it's the more useful half.

## Why RAUC and not Mender

Mender bundles a fleet-management server (hosted or a heavy
docker-compose). RAUC is only the update *mechanism*: you build a signed
bundle and deliver it however you like. No server, no account, every
moving part visible — which is the point here. Mender's value is the
thing we specifically don't need on a desk.

## The idea in one paragraph

Two complete copies of the rootfs on the card (slots A and B). You run
from one and write the other, so the system that could rescue you is
never the one being modified. A bootloader with persistent writable state
picks the slot and counts attempts; a slot that never checks in gets
abandoned. That "check in" is a deliberate userspace declaration —
`rauc status mark-good` — not something the kernel does for you.

## What we added

- `meta-rauc` — the client + `bundle.bbclass`.
- `meta-rauc-community/meta-rauc-raspberrypi` — the BSP glue: dual-rootfs
  `.wks`, the A/B `boot.cmd`, fstab, kernel fragment. Note you add the
  *sub-layer*, not the repo root.
- `meta-lts-mixins`, branch `scarthgap/u-boot` — **mandatory for the Pi 5.**
  Scarthgap froze U-Boot at 2024.01, which predates usable Pi 5 support;
  this "mixin" layer backports 2025.04. One branch per backported
  component, hence the odd branch name. It's a hard `LAYERDEPENDS` of
  meta-rauc-raspberrypi.
- `playground.conf`: `DISTRO_FEATURES:append = " rauc"`. Load-bearing in
  three places — meta-rauc's sanity class warns without it; the BSP's
  `rauc-integration.bbclass` turns it into an *override* named
  `rauc-integration` (so bbappends can write `:rauc-integration` and work
  either way — a trick worth stealing); and through that override the
  kernel gains dm-verity/squashfs/loop/nbd and `rpi-u-boot-scr` gains the
  A/B boot script.
- `playground-image.bb`: the `rauc` package. Capability vs contents, same
  boundary session 8 drew for INIT_MANAGER.
- `local.conf`: `RPI_USE_U_BOOT`, the dual `WKS_FILE`, `ext4` in
  IMAGE_FSTYPES (the bundle payload — a `.wic` is a whole disk and useless
  for that), key paths, and a `BBMASK`.
- Ours: `rauc-conf.bbappend` + `system.conf`, `playground-bundle.bb`,
  `scripts/rauc-gen-keys.sh`.

### Two things worth remembering

**BBMASK.** Both meta-rauc-raspberrypi and meta-playground want to own
`/etc/rauc/`, and both sit at `BBFILE_PRIORITY` 6 — so "which wins" would
depend on parse order. `BBMASK` vetoes one file from a third-party layer
by regex on its path. Cleaner than forking, and it's one tracked line.

**Key split.** The private signing key is generated onto the build disk
and never enters this repo (plus `*.key.pem` in `.gitignore` as a
backstop). The CA *certificate* is tracked deliberately — it's public by
design, and every image must carry it as its trust anchor.

## Corrections to earlier assumptions

- **The kernel is per-slot.** `boot.cmd` sets `BOOT_DEV` to `mmc 0:2` or
  `mmc 0:3` — the chosen slot's *rootfs* — then `load ${BOOT_DEV} ...
  boot/Image`. So U-Boot reads the kernel out of the slot's own `/boot`,
  and a bundle updates it along with everything else. The copy of `Image`
  in the FAT partition is deployed but never booted from.
  What genuinely stays shared: `config.txt`, `cmdline.txt`, the device
  tree and our overlays, the GPU blobs, and U-Boot itself — everything the
  firmware touches before U-Boot exists. Changing those still needs the
  card in your hand.
- **`CMDLINE_ROOTFS` belongs to `rpi-cmdline.bb`.** meta-rauc-raspberrypi
  tries to strip the hardcoded `root=` with a `CMDLINE:remove` in its
  *kernel* bbappend, where it has no effect — a bbappend's variables only
  touch its own recipe's datastore. We set `CMDLINE_ROOTFS` in local.conf
  instead. Not fatal either way (Linux honours the last `root=`), but the
  upstream version is a booby trap.

## Verified on target

```
/proc/cmdline: ... console=tty1 root=/dev/mmcblk0p2 rauc.slot=A
```
`root=` was deliberately removed from `cmdline.txt`, and `rauc.slot` never
existed there — so both were appended at runtime by `boot.scr`. That one
line is end-to-end proof: firmware → U-Boot → boot script → slot
selection → kernel.

```
rauc status: Booted from rootfs.0 (A) / Activated: rootfs.0 (A)
             both slots "boot status: good"
fw_printenv:  BOOT_A_LEFT=3  BOOT_B_LEFT=3  BOOT_ORDER=A B
rauc-mark-good.service: "marked slot(s) rootfs.0 as good"
```

`BOOT_A_LEFT=3` is the one to watch. Every boot *decrements* it before
booting the slot; only `rauc status mark-good` puts it back. If mark-good
ever stops running, a perfectly healthy system gets rolled back after
three reboots. It can't brick the board though — when no slot has tries
left, the script resets both counters and reboots.

---

# The debugging half, which is the actually useful part

The image didn't boot for most of this session. We never found out why.
What follows is worth more than the fix would have been.

## Dead ends and what killed them

**`flash-sd.sh` looked hung.** Real bug, now fixed. `conv=fsync` meant
`dd status=progress` raced to 100% at page-cache speed and then blocked
silently for minutes flushing to the card — progress display frozen at
"done" exactly when pulling the card is most destructive. The image
doubled in size this session (two rootfs slots), turning a blip into a
multi-minute dead terminal. Now three visible phases: write, a background
`sync` with a live backlog readout from `/proc/meminfo` Dirty+Writeback,
and a byte-for-byte read-back verify.

**"It booted magically."** It hadn't. The white/red screen with the QR
code is the Pi 5 EEPROM bootloader's *recovery* screen, shown when it
finds nothing bootable — in this case because the card was still in the
PC. Lesson: ask what's actually on the screen before theorising. Two
turns were spent on a "boot counter" that could not exist.

**Serial console on the Pi 5 is not where you think.** From the DT
aliases in `bcm2712-rpi-5-b.dtb`:
```
serial0  = /axi/pcie@120000/rp1/serial@30000   <- GPIO14/15, on RP1 behind PCIe
serial10 = /soc/serial@7d001000                 <- the SoC's own UART
```
U-Boot can only drive the SoC's PL011 (`serial10`), which comes out of the
**dedicated 3-pin debug connector** — not the 40-pin header. The *kernel*
console, meanwhile, is `serial0` = GPIO14/15 = `ttyAMA0`. So jumper wires
on pins 8/10 will show Linux but never U-Boot. Seeing U-Boot needs the
JST-SH debug cable. (Worth buying before the capstone.)

## The forensic trick that made progress possible without serial

`boot.cmd` calls `saveenv` *before* loading the kernel, and the env lives
in `uboot.env` on the FAT partition. So the file's presence and its
`BOOT_x_LEFT` values are a flight recorder readable from any PC:

- file absent → U-Boot never reached the script
- counter decremented → it ran the script and died later

You can also *write* that file to reconfigure U-Boot with no rebuild —
`mkenvimage -s 0x4000 -o uboot.env env.txt` — because a saved environment
**replaces** the compiled-in defaults wholesale rather than merging with
them. (Corollary trap: once a device has saved an env, changes you bake
into the recipe stop applying to it.)

## The bisect, and the result

Failure mode: black screen, nothing on HDMI, no SSH, no `uboot.env`.
Bypassing U-Boot entirely (`kernel=Image` in config.txt + `root=` back in
cmdline.txt) booted fine — proving image, kernel, rootfs, partition layout
and RAUC config were all sound, and isolating the fault to U-Boot.

A crafted `uboot.env` with three changes then booted. Leave-one-out:

| test | reverted to stock | result |
|---|---|---|
| 1 | `bootcmd` = `bootflow scan` | **boots** — bootstd innocent |
| 2 | `preboot` = `pci enum; usb start;` | **boots** — preboot innocent |
| 3 | `stdin` = `serial,usbkbd` | **boots** — usbkbd innocent |
| 4 | valid env → corrupt CRC | **boots** |
| 5 | env file deleted entirely | **boots** |

All three suspects innocent. Test 5 is the negative control and it
demolished the remaining hypothesis: with no `uboot.env` at all — the
exact original state, `config.txt` and `cmdline.txt` byte-identical to
the build output — it booted anyway. `saveenv` also created the file from
scratch without trouble, which positively disproves the "first-ever FAT
env write hangs" story I'd built from reading `env_fat_save()`.

**Six boots since, six successes.** One failure ever, never reproduced.

## Lessons

1. **I applied the fix in every experiment without realising.** Each test
   env I wrote also *created* `uboot.env` — a fourth variable I never
   controlled for and which, ironically, is the one I later suspected. If
   the negative control hadn't been run, we'd have committed a U-Boot
   config fragment overriding three settings that do nothing, and been
   baffled when it didn't help on the Pi Zero W.
2. **Run the negative control before believing the explanation.** Five
   green results in a row are not evidence until you can also make it red
   on demand. Fail → fix → fail → fix.
3. Plausible mechanism + working system is *not* understanding. Both
   stories I told (bootstd vs distro_bootcmd; first-time FAT env write)
   were specific, sourced from real code, and wrong.

## Still open — and a late lead

Reliability check: **10/10 power cycles booted.** But every one of those
ten, and the six before, had the **Ethernet cable plugged in**. The only
failure this project has ever seen was the one boot with it *unplugged* —
a variable neither of us was tracking, remembered after the fact.

One-for-one correlation on n=1, so not a conclusion. But there is a
mechanism that fits. Stock U-Boot runs `bootcmd=bootflow scan` over
`boot_targets=mmc usb pxe dhcp`. Normally `mmc` yields `boot.scr` at once
and the network is never touched. If `mmc` misses even transiently, it
falls through to `pxe` then `dhcp` — and with **no link** U-Boot's network
retry can sit there indefinitely, which from outside is indistinguishable
from a hang. With a live link, DHCP answers off the dev PC in
milliseconds, fails to find a boot file, and the moment passes.

That needs no component to be broken: a marginal SD read only becomes a
permanent-looking hang when the fallback path has nothing to fail
against. It also lets the card-reseating story be partly true.

Tested immediately: **5/5 boots with Ethernet unplugged.** Hypothesis
dead. Third confident, mechanistically-plausible story to die by
measurement in one session.

## Final disposition: unreproducible

**16 boot attempts, 15 successes.** The single failure is the very first
one, and it has survived no attempt to recreate it: original config,
stock env, no env, corrupt env, with and without Ethernet, with and
without a saved bootloader environment.

Leading suspect remains **SD card seating** — the one physical thing that
definitely changed between the failure and every success since. (Two
separate incidents this session involved the card not being where we
thought it was, which is its own kind of evidence.)

Recorded as *unreproducible, monitored, not fixed*. That is a real
engineering disposition, and a better one than committing a speculative
fix and calling it solved. **No fix committed.** If it recurs we now have
two things we didn't have at the start: the `uboot.env` forensic
technique, and the knowledge that seeing U-Boot needs the JST-SH debug
cable.

### One change worth making anyway — on merit, not as a fix

Pinning `boot_targets` to `mmc` (or setting an explicit `bootcmd` that
loads `boot.scr` directly) is worth doing *independently*: it makes boot
deterministic, and it stops the board probing USB, PXE and DHCP whenever
anything hiccups. Boot time is the entire point of the Pi Zero W
capstone, and that probing is pure latency.

If we do it, it goes in as a deliberate design decision with that
rationale — explicitly **not** as a fix for the failure above, which we
cannot demonstrate it would have prevented.

Then: build the bundle, `rauc install` it, boot into slot B, force a
rollback. **Done in notes/17** — all four, plus an unplanned lesson about
HTTP range requests and another about per-slot machine identity.
