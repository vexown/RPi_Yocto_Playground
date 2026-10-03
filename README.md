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
- [x] Build your own distro conf — playground distro (INIT_MANAGER policy moved out of local.conf), /etc/os-release verified 2026-07-25 (notes/13)
- [x] Package feeds & runtime package management — rpm feed served from the PC, `dnf install less` on the running Pi 2026-07-25 (notes/14)
- [x] SDK generation (`bitbake -c populate_sdk`) — installed to /opt/playground/0.1, sdk-demo app built outside Yocto + ran on target 2026-07-25 (notes/15)
- [x] OTA updates (Mender or RAUC layer) — RAUC A/B: boot chain verified
      2026-08-09 (notes/16); signed bundle streamed over HTTP onto the running
      Pi, booted slot B at 0.2, then forced a rollback to slot A at 0.1 by
      masking `rauc-mark-good` — counters 2→1→0→fallback, 2026-08-15
      (notes/17) — **Phase 5 complete**
- [x] OTA follow-up: fix the state that updates were destroying — SSH host
      key moved to `/data` via a dropbearkey drop-in, `resize=true` on both
      slots; installed A→B→A and switched slots with no host-key change,
      2026-08-16 (notes/18). machine-id measured as per-slot too, documented
      but deliberately not fixed (needs an initrd).

Phase 6 — CAPSTONE: real product on the Pi Zero W
Replace Raspberry Pi OS Lite (~2 min boot) on the deployed USB serial
logger with a purpose-built image (target: boot to working SSH + logging
in ~10-15 s):
- [x] Second build config: MACHINE=raspberrypi0-wifi (ARMv6) — `build-rpi0`,
      `conf-templates/local.conf.rpi0`, `setup-yocto.sh` takes a target
      argument; `core-image-minimal` built 2026-08-17 (notes/19)
- [x] Baseline: measure current Pi OS boot — **86.9 s** (12.4 s kernel +
      74.5 s userspace), of which `NetworkManager` alone is 43.0 s, 2026-08-17
      (notes/19). Measuring also found the deployed logger crash-looping on a
      hardcoded `/dev/ttyUSB0` and burning 100% of the core on a busy-wait.
- [x] Minimal image: `rpi0-logger-image`, its own recipe so no bbappend
      written against `core-image-minimal` can reach it — **45.9 MB / 112
      packages**, vs 59.4 MB for `core-image-minimal` on the same board,
      2026-08-18 (notes/20). systemd not sysvinit, as the logger's
      udev/`BindsTo=` activation requires. Also fixed the `:rpi`-scoped
      fstab that would have dropped this two-partition card into an
      emergency shell, replaced NetworkManager with systemd-networkd +
      wpa_supplicant, and made `/var/log` persistent so the logger's
      captures are not written to tmpfs. Built, **not yet flashed**.
- [x] Recipe for the USB serial logger — `meta-playground/recipes-apps/serial-logger`,
      rewritten in C (9.6 KB binary), udev rule instantiates a systemd
      template unit per device, `BindsTo=` replaces the crash loop; verified
      on the Pi 5 2026-08-17 (notes/19)
- [ ] Measure, then optimize — **21.39 s** mean (kernel + userspace,
      `systemd-analyze`) vs the 86.9 s Raspberry Pi OS baseline; noise
      floor ±0.12 s over three boots, 2026-08-20 (notes/20, 21, 22).
      Session 16 profiled it: the boot is **work-bound, not wait-bound**
      — 21.4 s busy against 0.6 s idle on one ARM11 core, 97% saturated.
      Module compression (0.15 s), console cost (no framebuffer) and SD
      throughput (21 MB/s) all ruled out; `force_turbo=1` changed nothing
      because `ondemand` was already at 1000 MHz. Session 17 shipped three
      changes for **−0.616 s** (5.5× the noise floor), all of it from
      dropping the vc4 overlay and `busybox-syslog`. `10-wifi-early.conf`
      moved `brcmfmac` from 21.3 s to 10.2 s and removed `wlan0.device`
      from the critical chain, contributing 0 s to the printed total by
      construction — reordering conserves work (notes/21 §6, corrected).
      Not ticked, and the reason changed: **`systemd-analyze` is not the
      goal metric.** The board had no IP until **24.9–30.5 s** — up to 9.3 s
      of DHCP *after* the reported finish line (notes/22 §4). Cause found:
      the **first DHCP exchange fails on every boot** (5/5), so networkd
      waits out RFC 2131's 4 ± 1 s backoff before a retry that succeeds in
      ~25 ms. Session 18 fixed it with a **static address**, which is not a
      faster conversation but the absence of one — a netlink call has no
      packet to lose. Time-to-goal **~21.25 s**, and the printed total did
      not move (21.44 s), exactly as the two-clock model predicts
      (notes/23). The address is a property of the *site*, not the product,
      so it is applied by `provision-card.sh` as a networkd drop-in and the
      image still ships DHCP: opt in to the fast path, fall back to the safe
      one. Session 18 then took two lever-1 units out, measured separately
      with `systemctl mask` before writing any recipe: **`systemd-logind`
      −1.344 s** (last gate on `multi-user.target`, on a board whose only
      login is dropbear) and **`systemd-vconsole-setup` −0.487 s** (a console
      font for a board with no framebuffer since session 17). **21.390 →
      19.472 s** mean over six boots, −1.918 s / 9.0%, carrier at 20.52 s.
      Then **`systemd-resolved` −0.788 s** (a caching DNS proxy on a board
      with one interface and no `resolve` entry in `nsswitch.conf`).
      **21.390 → 18.684 s**, −2.706 s / 12.7%, carrier 19.72 s ± 36 ms.
      The interesting result is a rule that broke: after vconsole (63% of
      blame) and logind (73%) it looked like *blame is an upper bound worth
      two thirds*, and resolved returned **15%**. Blame cannot distinguish a
      unit that was **busy** from one that was **blocked**, and only the
      first kind gives its time back, and `CPUUsageNSec` does not predict it
      either — it under-promises by 1.3–2.6×, where blame over-promises.
      Neither is an estimator; CPU time is only useful for *ranking*.
      Then `systemd-userdbd` −0.795 s, and all four folded into
      `meta-playground/recipes-core/systemd/systemd_%.bbappend` as
      `PACKAGECONFIG:remove = "vconsole logind resolved nss-resolve userdb"`,
      rebuilt and reflashed: **21.390 → 17.677 s, −3.713 s (17.4%)** over six
      boots, carrier 18.31 s. Removal beat masking by a further 0.212 s
      because systemd no longer parses the unit files at all. Still not
      ticked: the remaining time-to-goal variance lives in the
      **wpa_supplicant association path** — ~1.56 s between daemon init and
      association attempt, never instrumented, and no lever-1 work will touch
      it (notes/23 §9, §13).
- [x] **The product actually works, away from home** — 2026-08-25 (notes/24).
      First run of the serial logger on this board: dwc_otg host mode, a
      CMSIS-DAP Debugprobe enumerating as `cdc_acm`/`ttyACM0`, the udev rule
      matching on USB *ancestry* rather than node name, `SYSTEMD_WANTS`
      instantiating the template, bytes on the card. That last point is the
      one the rewrite was for — the deployed Python script only knew
      `/dev/ttyUSB*` and could not see this device at all.
      Then proven on a **phone hotspot**: one provisioned card, two
      `network={}` blocks, DHCP address `10.199.167.62/24` from the phone,
      found by `scripts/find-board.sh` sweeping the laptop's own subnet and
      matching the board's MAC. Discovery lives on the laptop deliberately —
      the alternative is avahi + dbus + a rebuild. Across the whole network
      change the open log file went **797 → 5872 bytes with no gap**: the
      unit's only dependency is `BindsTo=dev-%i.device`, so losing the
      network costs the ability to *read* logs live, never to collect them.
      Two things had been quietly riding on the home LAN and now do not:
      `/etc/resolv.conf` is written unconditionally from public resolvers,
      and NTP servers are provisioned **by IP** (timesyncd's compiled-in
      fallback is `time1-4.google.com`, so the clock depended on DNS).
      Measured: the clock is true at 27.5 s, of which the NTP round trip is
      32 ms — the rest is the same RFC 2131 first-exchange failure from
      session 18, reproduced independently. Also found and fixed: the WiFi
      PSK was stored **plaintext** on the card, so the Zero W ran PBKDF2 at
      every boot (`scripts/add-wifi-network.sh`).
- [x] **Reachability that survives a hostile network** — 2026-08-25
      (notes/25). The board became unreachable for **5 m 18 s per boot** on a
      LAN it had worked on for weeks: carrier at 18 s, DHCP address at 336 s,
      reproducible to within two seconds across boots seven minutes apart.
      That interval is RFC 2131's retransmission ladder summed out
      (2+4+8+16+32+64+64+64+64 = 318 s from carrier), so it is the client
      retrying its way to success, not the server recovering — which also
      ruled out the router reboot as either cause or cure. Root cause is
      **still unknown** and lives in the router's DHCP server; it is
      intermittent (8 s earlier the same day, 26 s after the fix).
      Fixed by routing around it: `provision-card.sh` now writes a **hybrid**
      drop-in — `Address=` *and* `DHCP=ipv4`, with the static gateway at
      `Metric=2048` so DHCP's 1024 still wins wherever a server exists.
      Claiming an address is a netlink call, so the board is reachable at
      carrier whatever DHCP does. **336 s → 17 s**, and clock sync improved
      27.5 s → 19.3 s as a side effect, because timesyncd was waiting on DHCP
      too. The original case for a static address was 4 seconds of boot time;
      the real case is being reachable when the network refuses to cooperate.
      Getting there cost three wrong diagnoses of mine — power save, the power
      supply, a dying SD card — all built on one observation that turned out
      to be an artifact: journald's default `SyncIntervalSec=5m` meant every
      hard-powered-off boot's journal appeared to stop at 18.7 s. **The
      instrument shared a failure domain with the fault.** The image already
      ships a channel that doesn't (`console=serial0,115200`, `serial-getty`
      enabled) and it has still never been used.
- [x] **The first day in the field, and the two faults it found** —
      2026-09-05 (notes/26). Total failure at work: the finder hung and no
      log was written. Both real, both below the layer session 24 proved.
      **The bench proof was a proof about the wrong device.** `cdc-acm` is
      the one *complete* driver in this image — it registers a tty by
      itself — while every other is a bridge driver delegating to
      `usbserial`. So a green light from a Debugprobe was never evidence
      about the work adapter, which turned out to be a **PL2303**
      (`067b:2303`) whose driver we had simply never shipped: the device
      enumerates cleanly and the chain stops, no tty, nothing for the udev
      rule to match, silent at every layer that has diagnostics. Fixed and
      verified — a full boot of the target captured end to end. A first
      guess blaming `usbserial` was wrong and is kept in the recipe:
      `modprobe ftdi_sio` pulled it in unaided, so `kernel-module-split`
      *does* generate link-time module deps, and the `brcmfmac-wcc` lesson
      is only about runtime `request_module()`.
      Second fault: hot-plugging the harness **resets the board**. Not the
      adapter's inrush (alone it is fine), not the target's draw (it resets
      with the target switched off), and not a Zero W limitation — the old
      Pi OS deployment ran this same rig while burning 100% of the core on a
      spin loop, so it had *less* headroom. It is the insertion transient
      only, and the proof was already in the failure: the board's own reset
      cycle **is** the connect-then-power test, and it passes. On a PC the
      USB port is a load on a supply; on a Zero W the OTG VBUS *is* the node
      that feeds the SoC's regulator. Closed with a procedure — connect
      before power — which is likely why Pi OS never met it.
      Also fixed: `find-board.sh` swept every route the host had, including
      a VPN tunnel whose 65534 addresses are not on the local wire and so
      cost a full timeout each. Now skips tunnels and bridges, clamps
      anything wider than `/22`, times each sweep, and caches the last hit.
      **Untested on a hotspot.**
- [x] **(a) The filename corrects itself** — 2026-10-03 (notes/27),
      VERIFIED on hardware. A `timerfd` on `CLOCK_REALTIME` created
      `TFD_TIMER_CANCEL_ON_SET` joins the `poll()` loop the program already
      had; the timer is never meant to fire, we want the kernel
      *cancelling* it when the clock is **stepped**, which arrives as
      `read()` returning `ECANCELED`. The logger then computes
      `realtime_now − monotonic_elapsed` and `rename()`s its own file — an
      open fd refers to the file, not the name, so no reopen and no lost
      bytes. No ordering dependency: `After=time-sync.target` is the
      obvious fix and the wrong one, putting the network in front of a USB
      reader. Measured in one boot: wrong name at 19.50 s, corrected at
      21.19 s, accurate to the second.
      **The race is nondeterministic, which is why this matters.** Same
      card, two boots four minutes apart: NTP landed at 18.19 s on one and
      20.34 s on the other against a logger that starts at ~18.9 s. The
      name was not reliably wrong, it was *sometimes right*. Both bad forms
      were found on the card — the image build date (first boot after a
      reflash) and the last-run time (every boot after) — so the error
      equals however long the board was off.
- [x] **(b) `SIGHUP` rotation and a disk budget** — 2026-10-03 (notes/27),
      tested on the host, NOT yet on hardware. The adapter cannot be
      unplugged without resetting the board, so captures accumulated into
      one file forever. Measured: ~77 bytes/sec, ~6.7 MB/day against
      29.5 MB free — **four days to a full rootfs**, which on an
      unattended logger is a board with no room to let you ssh in and fix
      it. `SIGHUP` rotates (safe to repurpose *only* because the port is
      opened `O_NOCTTY`, so a carrier drop cannot be mistaken for an
      operator), a size cap rotates through the same path, and a total
      budget prunes oldest-first scoped per device. Both limits live in
      `/etc/default/serial-logger`; 0 disables. Enforced at rotation
      boundaries, so usage reaches `budget + max_file_bytes` — bounded, not
      a hard ceiling. A bigger partition is not a fix: any fixed space
      loses to unbounded growth, it only moves the date.
- [ ] **(c) An ASCII-menu operator tool** on the target — an OS built to
      log serial devices still ships no way to *operate* the logging. Now
      has real primitives to wrap rather than being invented alongside
      them.
- [ ] **A separate partition for captures.** Not a substitute for (b): the
      caps stop the logger misbehaving, a partition contains the damage
      when something else does. A full dedicated partition stops logging; a
      full rootfs stops the board. Note the 100 MB rootfs is
      `IMAGE_OVERHEAD_FACTOR` (1.3) over content with
      `IMAGE_ROOTFS_EXTRA_SPACE` unset — the rest of the card is
      unallocated, since Yocto does not expand on first boot the way Pi OS
      does.
- [ ] Read-only rootfs so yanking power can't corrupt the SD card —
      **now has a known consequence, measured 2026-08-25** (notes/24 §10).
      `var-volatile-{lib,cache,spool,srv}.service` are all gated on
      `ConditionPathIsReadWrite=!/var/lib` and are *skipped* today, so
      `/var/lib` is on the SD card. Make `/` read-only and they activate:
      timesyncd's clock file becomes RAM-backed, every boot restores the same
      compiled-in epoch (`2025-05-29 18:48:29`), and boot-time log files
      collide on one name and append to each other. The boot already passes
      through three clocks — that epoch, then the last shutdown at ~15.4 s,
      then NTP at ~27.5 s — and the logger starts at 18.8 s, a margin of only
      3.3 s. The fix belongs with this change, not before it.

## Notes

Session-by-session journal in `notes/`.
