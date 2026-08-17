# Session 14 — Phase 6 opens: measure the thing before replacing it

The capstone. The Pi Zero W in the drawer is a real deployed product — a USB
serial logger on Raspberry Pi OS Lite that takes about two minutes to boot —
and the goal is to replace it with a purpose-built Yocto image that reaches
working SSH plus logging in 10–15 s.

The first two checkboxes are a second build config and a baseline
measurement. Neither is glamorous. Both had to happen before anything got
flashed, because **the board in hand was the only copy of the product and
the only place the baseline existed**, and a Yocto card destroys both.

Status: **build config done, baseline captured, logger rewritten and
verified on target.** Image recipe and networking are next.

## 1. A second build config (checkbox 1)

Two boards now, so two build directories:

```
rpi5  ->  build-rpi5  ->  MACHINE=raspberrypi5        (ARMv8, learning rig)
rpi0  ->  build-rpi0  ->  MACHINE=raspberrypi0-wifi   (ARMv6, the product)
```

`conf-templates/local.conf` became `local.conf.rpi5`, joined by
`local.conf.rpi0`; `scripts/setup-yocto.sh` takes a target argument and
defaults to `rpi5` so every command in notes/01–18 still works verbatim.
They share `DL_DIR`, `SSTATE_DIR` and one `bblayers.conf`.

BitBake can build several machines from one build directory — work and
sstate are keyed by architecture and don't collide. The reason to split is
`local.conf` itself: almost every line of the Pi 5's is a statement about
the Pi 5 (dual-slot wic, RAUC keys, an LED overlay on GPIO17, a package feed
reachable over an ethernet cable the Zero W does not have). Guarding half a
file with `:append:raspberrypi5` for no benefit is worse than two files.

The rpi0 config is deliberately *smaller*. No `RPI_USE_U_BOOT` — the
firmware loads the kernel directly, removing a whole stage from the boot
path; U-Boot earned its place on the Pi 5 because A/B slot selection needs a
writable environment, and nothing here needs that yet. No dual-slot wic, no
RAUC keys, no `PACKAGE_FEED_URIS` pointing at an ethernet address that
cannot exist on this board.

One thing kept: `ENABLE_UART = "1"`. You cannot optimise a boot you cannot
watch, and there is no ethernet to SSH in over while the board is still
booting. Board-specific detail worth remembering: the Zero W's good UART
(PL011, `ttyAMA0`) is wired to the Bluetooth controller, so GPIO14/15 is the
**mini-UART** `ttyS0`, whose baud derives from the VPU core clock — which is
why `enable_uart=1` also pins `core_freq` to 250 MHz. A small permanent
performance cost, paid for visibility.

### What ARMv6 costs

`DEFAULTTUNE = "arm1176jzfshf"`. Single ARM1176JZF-S core at 1 GHz, 512 MB.
sstate is keyed by architecture, so every *target* package rebuilds from
source; only the x86_64 native/cross toolchain is reused, and `DL_DIR` is a
full hit.

I predicted hours. It took **20 minutes** — the native/cross reuse carries
more than I credited, on a fast desktop. Worth recording precisely because
the wrong prediction is the interesting datum: the expensive part of a
cross-build is mostly host-side, and that part was already cached.

(Do not confuse `raspberrypi0-wifi` with `raspberrypi0-2w`. The Zero 2 W is
BCM2710, quad-core ARMv8 — different silicon behind an identical outline.
Picking wrong gives you an image that builds perfectly and never boots.)

## 2. The baseline (checkbox 2)

`systemd-analyze` on the deployed board, Raspbian trixie, kernel 6.18.34:

```
Startup finished in 12.435s (kernel) + 1min 14.504s (userspace) = 1min 26.940s
```

Decomposed from the critical chain:

| Stage | Cost | Cumulative |
|---|---|---|
| Kernel (start → userspace) | 12.4 s | 12.4 s |
| userspace → `basic.target` | 24.9 s | 37.3 s |
| `NetworkManager.service` | **43.0 s** | 80.3 s |
| `ssh.service` | 3.4 s | 83.7 s |
| → `multi-user.target` | | **86.9 s** |

Three separate problems needing three different fixes.

**NetworkManager is half the boot.** And it holds up everything behind it:
`ssh.service` is ordered `After=network.target`, and `network.target` is
only reached when NM's start job completes — so an SSH daemon sits idle for
43 s waiting on WiFi association and DHCP before it will open a socket.

**25 s to `basic.target` is the general-purpose-distro tax.** Read the blame
list sideways: `modprobe@configfs`, `modprobe@drm`, `modprobe@efi_pstore`,
`modprobe@fuse`, `sys-kernel-tracing.mount`, `dev-mqueue.mount`,
`systemd-rfkill`, `e2scrub_reap`, `udisks2`, `apparmor`. Each 1.5–4 s of a
desktop distro's boot sequence on one 1 GHz ARMv6 core off an SD card.
`dev-mmcblk0p2.device` alone took 14.3 s to settle. This is the part Yocto
deletes for free by never installing it.

**12.4 s of kernel is the one that should worry us**, because the target is
10–15 s *total*. Pi OS ships a general-purpose kernel with an initramfs; our
Yocto build already skips the initramfs, which is a real head start.

Also captured as requirements rather than bugs: `avahi-daemon` is what makes
`rpi0.local` resolve, so dropping it costs the name we connect by; and the
board has no RTC, so `systemd-timesyncd` restoring the clock from
`/var/lib/systemd/timesync/clock` is all that stands between us and 1970
timestamps in early boot.

## 3. What the measurement actually found

The point of measuring first is that it tells you things you did not set out
to learn. The boot time was the third most interesting result.

### The logger had not started successfully this boot

```
serial-logger.service @25min 28.678s
```

Twenty-five *minutes*. `systemd-analyze` reports when a unit last became
active, and this one was on a three-second crash loop: `Restart=always`,
`RestartSec=3`, and a script that calls `sys.exit(1)` the moment the port
cannot be opened. The evidence was in plain sight — every `session_*.log`
dated Jul 10, but `error.log` at 137 KB, last written *during the session*.

### Why: the wrong device node, hardcoded

```
Bus 001 Device 002: ID 2e8a:000c Raspberry Pi Debugprobe on Pico (CMSIS-DAP)
  bInterfaceClass  2 Communications / Abstract (modem)   <- CDC-ACM
```

A Debugprobe is CDC-ACM. It binds `cdc_acm` and appears as `/dev/ttyACM0`.
The script said `PORT = '/dev/ttyUSB0'`, which is what `ftdi_sio` / `cp210x`
/ `ch341` produce. Different driver, different node. The July logs prove a
`ttyUSB` adapter worked then; the script only ever knew about one kind of
hardware.

### The busy-wait, measured rather than asserted

```python
while True:
    if ser.in_waiting > 0:
        line = ser.readline()
```

Ran the deployed script verbatim (only `PORT`/`LOG_DIR` redirected to a pty)
against a silent port, next to the C rewrite:

```
deployed serial_logger.py, 5.0 s idle  ->  5.0000 s CPU
new serial-logger (C),     5.0 s idle  ->  0.0009 s CPU
```

100.00% of a core, doing nothing. On a single-core board that is the entire
machine. `readline()` already blocks for `timeout=1`; the `in_waiting` guard
is precisely what turns a blocking read into a spin loop.

### `flush()` is not `fsync()`

```python
# FORCE saving to SD card immediately so data isn't lost if power drops
log_file.flush()
```

It does not. `flush()` moves bytes from Python's buffer into the kernel page
cache; they are still in RAM and still lost to a power cut. Only `fsync()`
pushes them at the card. Right intent, wrong call — and the comment made the
gap invisible, which is the more general lesson about comments that assert
behaviour instead of explaining it.

## 4. The rewrite (checkbox 4)

`meta-playground/recipes-apps/serial-logger/`, five files: a C program, a
systemd **template** unit, a udev rule, an `/etc/default` file, and the
recipe. The old deployment was a Python script in `/home/blankmcu` and a
hand-written unit in `/etc/systemd/system`, both created by hand on a
running box and existing nowhere else. That difference is what this whole
project is about.

### udev instantiates the service

```
SUBSYSTEM=="tty", SUBSYSTEMS=="usb", TAG+="systemd", \
    ENV{SYSTEMD_WANTS}+="serial-logger@%k.service"
```

```ini
BindsTo=dev-%i.device
After=dev-%i.device
```

Singular `SUBSYSTEM` is the device's own; plural `SUBSYSTEMS` walks *up the
parent chain*. That is the load-bearing distinction: it matches serial ports
that hang off a USB device and never the Pi's own `ttyS0`/`ttyAMA0`, which
sit on the SoC platform bus. Without it we would log the boot console into
itself. Matching by ancestry rather than by driver is also why the rule needs
no maintenance — `ftdi_sio`, `cp210x`, `ch341`, `cdc_acm` and whatever ships
next year all produce a tty under a USB parent.

| Old unit | New |
|---|---|
| `/dev/ttyUSB0` hardcoded in the script | any node, named by udev |
| `After=network.target` → 43 s wait | starts when the *device* appears |
| crash-loops forever if absent | no device, no unit |
| dies on unplug, respawns, dies… | `BindsTo=` stops it cleanly |
| one adapter only | one instance per adapter, concurrently |

`BindsTo=` is what replaces `Restart=always`. The crash loop is not fixed so
much as made structurally impossible: there is no service to fail when there
is no device.

### Durability without wear

`fsync()` when *either* 8 KB has accumulated *or* the link has been quiet for
2 s. Worst-case loss is bounded, but a chatty device costs one flash write
per 8 KB instead of one per line. Per-line `fsync()` on an SD card, on a box
whose stated requirement is surviving a yanked power cable, would be the
opposite of durable.

Data goes to the file only, not also to stdout. Under systemd stdout *is*
the journal, so the original wrote every logged byte to the card twice.
Status and errors still go to stderr, which is what you actually want in
`journalctl`; watch data live with `tail -f` instead.

### Packaging notes

- `systemd.bbclass` handles `@` in `SYSTEMD_SERVICE` explicitly (it derives
  `foo@eth0.service` from `foo@.service`), so naming the template is correct.
- `SYSTEMD_AUTO_ENABLE = "disable"` — a template with no `[Install]` has no
  enablement state, and the default `"enable"` would try to preset a unit
  that cannot be preset. The generated postinst contains a visible
  `if [ "disable" = "enable" ]`, i.e. a deliberate no-op.
- No `FILES:${PN} +=` needed, and it is worth knowing *why* after session 13
  cost a build over exactly this: bitbake.conf's default `FILES:${PN}`
  already covers `${bindir}/*`, `${sysconfdir}`, and both
  `${base_prefix}/lib/udev` and `${prefix}/lib/udev`. The unit file is the
  only uncovered path, and the bbclass adds that itself.
- Unit and udev rule go in the **vendor** directories, not `/etc`. `/etc` is
  the administrator's; a package that writes there takes away their override.
  The config file *does* go in `/etc`, because it genuinely is theirs.

Result: **9,604-byte stripped binary**, 17.6 KB rpm, `RDEPENDS` of `udev`
and `glibc`.

## 5. A bbappend that reached across boards

`core-image-minimal` for the Zero W came out with **1732** `kernel-module-*`
packages. `playground-image` for the Pi 5 has **2**. Same distro, same BSP,
same layers.

I first said this was the BSP pulling `kernel-modules` in wholesale. Wrong.
The source is:

```
# meta-rauc-community/meta-rauc-raspberrypi/recipes-core/images/core-image-minimal.bbappend
IMAGE_INSTALL:append = " kernel-image kernel-modules"
RPI_EXTRA_IMAGE_BOOT_FILES:remove = "${KERNEL_IMAGETYPE}"
```

Sensible in its own world — with A/B slots the kernel must live inside the
rootfs so both slots can carry different ones. Meaningless on a Zero W with
no U-Boot and no A/B layout.

> **A bbappend attaches to a recipe NAME.** Not to a machine, not to a use
> case, not to the board the layer was added for.

A layer added in session 11 for the Pi 5's OTA silently reshaped a Pi Zero W
image four months later. `playground-image` escaped for one reason only: a
different name.

And the second line does not work. It targets `RPI_EXTRA_IMAGE_BOOT_FILES`,
but the kernel is in `IMAGE_BOOT_FILES`, set by `rpi-base.inc`. The built
image proves it:

```
IMAGE_BOOT_FILES non-dtb entries: ['bootfiles/*', 'zImage;kernel.img']
```

The kernel is on the FAT partition *and* in the rootfs — shipped twice. This
is the same class of bug as the `CMDLINE:remove` no-op already documented
from this exact layer in session 11's `local.conf`: a `:remove` aimed at the
wrong variable in a different recipe's namespace. The image still boots; it
just carries an extra kernel and 1732 modules it will never load.

**Consequence:** the Zero W gets its own image recipe — not for tidiness,
but so third-party bbappends on `core-image-minimal` cannot reach it. And
the 1732 modules were never a default we had to fight; they arrive with a
layer we can simply keep away from this board.

### The second instance, which would have hung the board

Going looking for other appends from the same layer turned up a worse one.
`meta-rauc-raspberrypi/recipes-core/base-files/base-files_%.bbappend`:

```
FILESEXTRAPATHS:prepend:rpi := "${THISDIR}/files:"
```

`:rpi` looks like scoping, and it is — but **every** Raspberry Pi machine
carries the `rpi` override, `raspberrypi0-wifi` included. So the layer's own
`fstab` wins the `file://fstab` lookup, and the built Zero W rootfs contains:

```
/dev/mmcblk0p5  /data   ext4    defaults         0       0
/dev/mmcblk0p6  /home   ext4    x-systemd.growfs 0       0
```

against a `.wic` that has exactly two partitions:

```
rpi0.wic1  *   8192  274431  266240   130M  c  W95 FAT32 (LBA)
rpi0.wic2    278528  587365  308838 150.8M 83  Linux
```

That is the Pi 5's RAUC partition layout, on a board where we deliberately
did not set `WKS_FILE`. Neither entry carries `nofail`, so systemd's fstab
generator gives each a hard `Requires=` on a device unit that will never
appear, pulled into `local-fs.target` — the device timeout (90 s by default)
expires, `local-fs.target` fails, and boot lands in emergency.

Reasoned from the config, not yet observed on hardware — the card was never
flashed. But it means the first Zero W flash would have hung with no serial
adapter to see why, and the natural suspicion would have been "the ARMv6
build is broken", which it is not.

Two takeaways beyond the specific bug. First, `:rpi` is a *machine family*
override, not a machine: reading it as "this only affects the Pi I set this
layer up for" is exactly the wrong inference. Second, the failure mode of a
misapplied bbappend is not a build error — both of these built cleanly. It
is a working artifact that is quietly wrong for the board it was built for.

## 6. Verified on target

Tested on the **Pi 5**, deliberately — it is already running, already
reachable, and already has session 14's package feed. Validate the mechanism
on the board that can talk to you before porting it to the one that cannot.

```
dnf install serial-logger kernel-module-cdc-acm
udevadm control --reload && udevadm trigger --subsystem-match=tty
```

```
* serial-logger@ttyACM0.service - USB serial logger on /dev/ttyACM0
     Loaded: loaded (/usr/lib/systemd/system/serial-logger@.service; static)
     Active: active (running) since Mon 2026-08-17 20:00:10 UTC
        CPU: 7ms
      CGroup: `-407 /usr/bin/serial-logger /dev/ttyACM0 115200 /var/log/serial-logger
```

`static` — no `[Install]`, exactly as designed, udev owns the lifecycle.
`CPU: 7ms` after 15 s of running confirms the busy-wait measurement on real
hardware. A log file named after the device appeared and started filling.

Then the test that actually mattered — pull the adapter out:

```
20:04:06 serial-logger[407]: /dev/ttyACM0 disappeared
20:04:06 serial-logger[407]: stopped logging /dev/ttyACM0
20:04:06 systemd[1]: serial-logger@ttyACM0.service: Deactivated successfully.
```

Both halves fired. The program's own `POLLHUP` path noticed and ran its
final `fsync()`; `BindsTo=` tore the unit down. "Deactivated successfully"
means it exited **0**, so `Restart=on-failure` correctly declined to
restart, and `systemctl status 'serial-logger@*'` afterwards returns
nothing at all — systemd garbage-collects inactive template instances that
nothing references. The crash loop is gone at the root, not papered over:
there is no unit left to fail.

The Pi 5 needed `kernel-module-cdc-acm` installed by hand, because
`playground-image` ships two kernel modules and `cdc_acm` is not one of them
— which is the flip side of section 5 and exactly the list the Zero W image
will have to state explicitly: `cdc-acm`, `ftdi-sio`, `cp210x`, `ch341`,
plus `brcmfmac` for WiFi. All are `=m` in both kernels.

Small operational note: `udevadm trigger` is asynchronous. It queues events
and returns; `udevadm settle` is what waits. A `systemctl status` run
immediately after trigger can legitimately show nothing.

## Next

- **Own image recipe for the Zero W** — immune to `core-image-minimal`
  bbappends, explicit about the four kernel modules it needs.
- **Deal with the fstab before the first flash.** An image recipe does not
  fix it: `base-files_%.bbappend` is scoped `:rpi`, so it applies whatever
  the image is called. Options, in rough order of preference: our own
  `base-files` bbappend at higher `BBFILE_PRIORITY` shipping a Zero W fstab;
  a `BBMASK` on that bbappend for the rpi0 build (the same tool already used
  against `rauc-conf.bbappend` in session 11); or give the Zero W the
  partitions the fstab expects, which is the tail wagging the dog. Whatever
  we choose, **check `/etc/fstab` in the built rootfs before flashing** —
  that one `cat` would have caught this.
- **Networking, and where the PSK lives.** The repo is public, so no
  credential can be tracked. Options: place `wpa_supplicant.conf` on the
  card after flashing (the workflow we already used for the SSH key), read
  it from the FAT boot partition at first boot, or point a recipe at an
  untracked absolute path via a `local.conf` variable. Also worth weighing
  for a Zero W: `CMDLINE_RNDIS` in `rpi-cmdline.bb` turns the OTG port into
  a network interface over the same cable that powers the board — no
  credentials, no association delay.
- **`NetworkManager` is not coming.** 43 s of the baseline. systemd-networkd
  plus `wpa_supplicant` directly.
- **Do not order the logger behind the network.** Already handled, but it is
  the single most valuable line from the baseline.
- Levers identified but deliberately not pulled until measured: trimming
  poky's desktop `DISTRO_FEATURES` (`libx11`, `libxcb`, `kbd-consolefonts`
  and `keymaps` are all in the current image on a headless board), the
  `rauc` distro feature's kernel config on a board with no A/B layout, and
  `journald Storage=volatile`.
- A dedicated unprivileged user for the logger (`useradd.bbclass` plus
  `GROUP=` on the udev rule) rather than running as root.

## State things were left in

- Deployed Pi Zero W: **untouched apart from an added SSH public key**, still
  running Raspberry Pi OS Lite, still the product. Its `serial-logger.service`
  is still crash-looping — deliberately not fixed in place, because it is
  being replaced.
- Full `dd` image of that card taken before anything else touched it:
  `/media/blankmcu/EmbeddedLinux/backups/rpi0-pios-lite-2026-08-17.img.gz`
  (888 MB gzipped). That is the rollback point for the whole capstone — if
  the Yocto image never works out, the product comes back with one `dd`.
- Pi 5: `serial-logger` and `kernel-module-cdc-acm` installed from the feed
  at runtime. Not in any image recipe — they vanish on the next reflash,
  which is fine, they were a test.
- `build-rpi0` exists with `core-image-minimal` built and never flashed.
- Ownership gotcha worth keeping: adding a key to a card's
  `authorized_keys` under `sudo` creates it `root:root`, and sshd's
  `StrictModes` then silently refuses it. `chown` to the uid from the card's
  own `/etc/passwd`.
