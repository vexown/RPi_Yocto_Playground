# Session 15 — The Zero W's own image, and reading a rootfs before you flash it

Session 14 measured the deployed product and rewrote the logger. This
session builds the OS that will carry it: `rpi0-logger-image`, its own
recipe, immune to the bbappends that reshaped `core-image-minimal`.

The image built on the second attempt and every subsequent problem was
found by reading the rootfs on the build machine, not by booting the
board. That turned out to be the more interesting story, so it gets its
own section at the end.

Nothing has been flashed yet. The Zero W is still running Raspberry Pi OS.

---

## 1. The image recipe (checkbox 3)

`meta-playground/recipes-images/images/rpi0-logger-image.bb`.

Why not `core-image-minimal`: a `.bbappend` attaches to a recipe NAME, and
`meta-rauc-community` appends to that one. Session 14 found it adding 1732
kernel modules to an ARMv6 board. The only reliable defence is to stop
using the name everyone appends to.

Why not `playground-image`: that is the Pi 5 learning rig — RAUC, package
management, an LED heartbeat, a hello-world binary. All of it useless or
costly here. The two boards run genuinely different products. They still
share a DISTRO, which is the right seam: same policy, different contents.

### The WiFi trap

This is the one that would have produced a booting board nobody could
reach, on hardware with no ethernet port.

`raspberrypi0-wifi.conf:8` does declare the firmware:

```
MACHINE_EXTRA_RRECOMMENDS += " \
    linux-firmware-rpidistro-bcm43430 \
    bluez-firmware-rpidistro-bcm43430a1-hcd"
```

But `MACHINE_EXTRA_RRECOMMENDS` is consumed by **packagegroup-base**, and
`packagegroup-core-boot` consumes `MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS`
(`packagegroup-core-boot.bb:39`). Different variable, different
packagegroup. A core-boot-based image on this machine gets no WiFi
firmware at all and the machine conf's declaration is silently inert.

Not a theory. After a full `core-image-minimal` build, `build-rpi0`'s
`tmp/deploy/rpm/` contained no `linux-firmware-rpidistro-bcm43430` rpm —
the recipe had never even been *built*, because nothing in the image graph
asked for it.

So the image names it. Verified in the built rootfs afterwards, and the
detail that justified choosing the rpidistro blob over poky's unflagged
`linux-firmware-bcm43430` showed up there:

```
brcmfmac43430-sdio.raspberrypi,model-zero-w.bin -> ../cypress/cyfmac43430-sdio.bin
brcmfmac43430-sdio.raspberrypi,model-zero-w.txt -> brcmfmac43430-sdio.txt
```

brcmfmac wants a board-specific NVRAM `.txt` next to the `.bin`, keyed by
the device-tree compatible string. The Foundation's package ships one per
board. Taking the BSP's word on which blob drives the radio was cheaper
than gambling on that file's existence.

### The licence gate

First build failed before compiling anything:

```
ERROR: Nothing RPROVIDES 'linux-firmware-rpidistro-bcm43430'
linux-firmware-rpidistro RPROVIDES ... but was skipped: Has a restricted
license 'synaptics-killswitch' which is not listed in your
LICENSE_FLAGS_ACCEPTED.
```

Two variables that are easy to conflate:

* `LICENSE` is a **statement of fact** — what the code is under. Never a
  gate.
* `LICENSE_FLAGS` is a **gate**. A recipe raises a named flag; the build
  refuses the recipe until the integrator names the same flag in
  `LICENSE_FLAGS_ACCEPTED`. It exists for licences a human is expected to
  read and consciously accept.

Putting the flag in `local.conf.rpi0` is that act of acceptance, recorded
in a tracked file rather than in someone's memory. (Pre-kirkstone the
variable was `LICENSE_FLAGS_WHITELIST`; scarthgap only knows the new name.)

Worth noting the flag is coarser than the thing it blocks.
`linux-firmware-rpidistro_git.bb:16` sets `LICENSE_FLAGS` at **recipe**
level, so one flag gates all nine packages. Ours declares its own licence
on line 70 as `binary-redist-Cypress-rpidistro` — Cypress, not Synaptics.
The Synaptics blobs are lines 71-75, other boards' radios this image never
installs. Not a bug; recipe-level granularity being coarser than
package-level licensing.

### Naming modules without pinning a kernel version

The real packages are versioned — `kernel-module-cdc-acm-6.6.63` — and
each `RPROVIDES` the unversioned name (`tmp/pkgdata/*/runtime/`). Naming
the unversioned form in `IMAGE_INSTALL` survives a kernel bump; the
versioned name becomes unresolvable the day meta-raspberrypi moves to 6.12.

### Result

| | core-image-minimal | rpi0-logger-image |
|---|---|---|
| compressed .wic | 59.4 MB | **45.9 MB** |
| packages | (1732 kernel modules) | **112** |

Smaller despite *adding* WiFi, firmware, wpa_supplicant and the logger.
That is the 1732 modules leaving.

---

## 2. The fstab, fixed properly (the notes/19 "Next" item)

meta-rauc-raspberrypi's `base-files_%.bbappend` is scoped `:rpi` — the SoC
family, from `SOC_FAMILY = "rpi"` in `rpi-base.inc:5` via `soc-family.inc`
— so its fstab demanding `/dev/mmcblk0p5 /data` and `/dev/mmcblk0p6 /home`
applied to the Zero W's two-partition card. No `nofail`, so
`local-fs.target` would time out and drop to an emergency shell.

notes/19 listed three remedies in preference order. **The first one does
not work**: both `meta-playground` and `meta-rauc-raspberrypi` are
`BBFILE_PRIORITY 6`, so there was no priority to win.

The actual mechanism is better than all three. `base_set_filespath()`,
`poky/meta/classes-global/utils.bbclass:277`:

```python
overrides = (":" + (d.getVar("FILESOVERRIDES") or "")).split(":")
overrides.reverse()
for o in overrides:          # outer loop: the override
    for p in path:           # inner loop: every layer's files dir
        filespath.append(os.path.join(p, o))
```

It is **override-major**, not path-major. Every layer's `files/<override>/`
is searched before any layer's plain `files/`. And `${MACHINE}` is
permanently the most specific override available: `MACHINEOVERRIDES ?=
"${MACHINE}"` is the seed (`bitbake.conf:816`) and every layer only ever
*prepends* with `=.`, so the bare machine name stays last in the string —
which `reverse()` turns into first-searched.

So `meta-playground/recipes-core/base-files/files/raspberrypi0-wifi/fstab`
beats `files/fstab` from anywhere, for that machine, permanently. No
`BBMASK`, no priority bump, and the Pi 5 keeps the fstab its five-partition
card genuinely needs.

Generalise: **when you need to override a file for one machine, the answer
is almost never a priority fight. It is a directory named after the
machine.**

---

## 3. Where the logs live

A near-miss worth recording because the image would have "worked".

The logger's unit declares `LogsDirectory=serial-logger`, so it writes to
`/var/log/serial-logger`. With poky's default `VOLATILE_LOG_DIR = "yes"`
(`bitbake.conf:91`), base-files never creates a real `/var/log` — systemd's
tmpfiles make it a symlink to `/var/volatile/log`, which the fstab mounts
as tmpfs. The logger would have run perfectly and lost everything on the
first power cut. Against a device that currently keeps months of captures
in `~/logs`, that is a regression dressed as an upgrade.

`VOLATILE_LOG_DIR = "no"` in `local.conf.rpi0`. One line, and it beats the
alternative of pointing `LOGGER_DIR` at a separate partition: that would
have needed a `ReadWritePaths=` in the unit (`ProtectSystem=strict` blocks
everything else), and a unit that differs per board is a unit that drifts.
The path did not move — only what is behind it.

Knock-on, checked rather than assumed: with a real `/var/log`, the rootfs
also gets `/var/log/journal`, and journald's default `Storage=auto`
persists exactly when that directory exists. So the **system journal is
persistent on this board**. For a headless unit with no serial adapter
that is a genuine asset — power-cycle it, pull the card, read the last
boot offline with `journalctl -D /mnt/var/log/journal`. It is also
unbounded SD wear. `SystemMaxUse=` goes on the optimize list.

---

## 4. Networking without NetworkManager

NetworkManager was 43.0 s of the 86.9 s baseline, with sshd ordered behind
it on `network.target`. Replaced by systemd-networkd (already inside the
systemd package, already enabled by upstream's `90-systemd.preset`) plus
wpa_supplicant directly. The whole thing is `rpi0-network`: four text
files, no new daemons.

Division of labour that trips people up: **networkd does not do WiFi.** It
does layer 3 — addresses, routes, DNS. Association and authentication are
layer 2 and belong to wpa_supplicant. They do not talk to each other.

Also worth noting from the enablement dump: dropbear is **socket
activated** (`dropbear.socket` in `sockets.target.wants`), so ssh costs
nothing at boot and has no ordering relationship with the network at all.
Half the baseline's ssh delay was an architectural choice Pi OS made, not a
law.

### A preset that enabled nothing

The image built clean, the preset file was in the rootfs, and
`wpa_supplicant@wlan0.service` was **not enabled**. No warning anywhere.

`systemctl preset-all` iterates over unit **files** on disk.
`wpa_supplicant@wlan0.service` is not a file — it is an instance name that
exists only once something instantiates the template. The preset policy is
looked up per collected unit file, so a rule naming an instance is never
consulted.

Why the same mechanism *does* work for `serial-logger`: that recipe names
its unit in `SYSTEMD_SERVICE`, and `systemd.bbclass`'s postinst then calls
`systemctl enable` on it **explicitly** — a different code path that
handles instances fine. Generalising from it was the mistake.

Fix: a drop-in giving `wpa_supplicant@.service` a `DefaultInstance=wlan0`,
and a preset that enables the **template**. A drop-in rather than a fork,
because poky's wpa-supplicant recipe owns that unit.

---

## 5. Reading a rootfs instead of booting it

Everything above except the licence gate was found without powering the
board. That is not an accident and it is not cleverness — it is a method,
and it is probably the highest-leverage Yocto skill there is.

**Why it matters here specifically.** The edit-to-observation loop is ~20
minutes to build, plus a flash, plus a boot. And this board is headless
with no 3.3 V UART adapter on hand: a failed boot may produce *no
information at all*. The read-the-rootfs loop is seconds. Anything that
converts the slow loop into the fast one compounds.

### The five moves

**1. Inspect the artifact, not the recipe.**
`tmp/work/<machine>/<image>/1.0/rootfs/` *is* the filesystem that will
boot. Symlinks, permissions, enabled units, installed firmware — all
answerable with `ls` before the card is written.

```bash
R=tmp/work/raspberrypi0_wifi-poky-linux-gnueabi/rpi0-logger-image/1.0/rootfs
cat $R/etc/fstab
ls  $R/etc/systemd/system/multi-user.target.wants/
ls -ld $R/var/log                      # directory or symlink?
awk -F: '$1=="root"{print $6}' $R/etc/passwd
```

**2. Run the build's own tools in isolation.** The highest-leverage move
and the least known. `systemd-systemctl-native` is a *Python script* that
takes `--root`:

```bash
poky/meta/recipes-core/systemd/systemd-systemctl/systemctl \
    --root=/tmp/fakeroot --preset-mode=enable-only preset-all
```

Build a throwaway tree with two unit files and a preset, and "would this
preset enable that unit?" is a five-second experiment instead of a
twenty-minute rebuild. That is exactly how the `DefaultInstance` fix was
chosen over two alternatives.

**3. Read the class, not the documentation.** The fstab question was
settled in about thirty seconds by reading `base_set_filespath` and seeing
the loop order. Documentation would have said "FILESPATH is searched in
order" and left the important part out. The layers are all git checkouts;
`grep -rn` is the API.

**4. Never confuse "the host does X" with "the build does X".** The
`DefaultInstance` fix was first validated against the host's systemd 255
— and the rootfs is not assembled by systemd at all. Poky substitutes its
own reimplementation. Host evidence is a hypothesis about the build, never
a result. Re-running against poky's script is what actually settled it.

**5. Ask what the failure would look like, not whether it succeeded.**
Every bug this session produced a **clean build**:

| bug | what the build said | what was wrong |
|---|---|---|
| rauc fstab reaching `:rpi` | success | p5/p6 on a 2-partition card |
| preset naming an instance | success | unit not enabled |
| `/home/root` in provision-card.sh | n/a | key where dropbear never looks |
| unscoped dropbear bbappend | success | A/B paths on a non-A/B board |

"Did it work?" gets you nothing from any of them. "If this were broken,
what would the rootfs look like, and does it look like that?" gets you all
four.

### The limit

Reading tells you what is **configured**. Only running tells you what
**happens**. This session produced a live demonstration: the unscoped
dropbear bbappend looked like a boot failure from the config, and reading
three more files showed it works — `dropbearkey.service` runs
`mkdir -p ${DROPBEAR_RSAKEY_DIR}` first, `/data` exists as a plain
directory, and `RequiresMountsFor` on a non-mount-point resolves to
`-.mount`. The first read produced a confident wrong answer; the fourth
produced the right one.

And two of the four bugs above were self-inflicted, caught only by
checking work that had just been written. The method includes distrusting
yourself.

---

## 6. A third bbappend reaching across boards — this one ours

`meta-playground/recipes-core/dropbear/dropbear_%.bbappend`, written in
session 13 for the Pi 5's A/B layout, **unscoped**. So the Zero W got
`DROPBEAR_RSAKEY_DIR=/data/dropbear` and a `dropbearkey` drop-in with
`RequiresMountsFor=/data`.

Sit with that one. The lesson from meta-rauc-community's
`core-image-minimal.bbappend` and `base-files_%.bbappend` did not
automatically apply to our own code. Reading someone else's bug does not
inoculate you against writing it.

As established above it is functional, not fatal — A/B vocabulary on a
board with no A/B, resting on a `/data` directory created by *another*
unscoped append. Now scoped `:raspberrypi5`, with
`PACKAGE_ARCH = "${MACHINE_ARCH}"` so the scoping is correct rather than
merely lucky in the tunes we happen to have.

Not scoped on the `rauc-integration` override despite playground.conf
recommending that trick: the distro enables the rauc DISTRO_FEATURE for
**both** boards, so both carry the override. What distinguishes them is
having a `/data` partition, and only the machine name says that.

### Running total

Four bbappends have now reached a board they were not written for:

1. `core-image-minimal.bbappend` (rauc layer) — 1732 kernel modules
2. `base-files_%.bbappend` (rauc layer) — the p5/p6 fstab
3. `dirs755 += "/data"` (same file, unscoped even within a `:rpi` append)
4. `dropbear_%.bbappend` (**ours**) — A/B host-key paths

Three of four were invisible at build time.

---

## 7. Housekeeping

`setup-yocto.sh` only installed the tracked `local.conf` on **first** init,
so editing a template left the live build dir stale and the next build
failed against config that looked correct in git. It now diffs the two on
every entry and reports functional differences, comment lines filtered out
(these templates are ~90% prose and a raw diff is unreadable). It
deliberately does **not** auto-copy — clobbering a config someone is
mid-experiment in is worse than a warning — and reports drift in both
directions, since "the build dir has something the template lacks" is
equally worth knowing.

`flash-sd.sh` now takes a target argument (`rpi5`/`rpi0`), same vocabulary
as `setup-yocto.sh`.

---

## 8. First flash: three causes, none of them visible from the rootfs

The board booted on the first flash and had no `wlan0`. The ACT LED was
solid green, which is worth knowing means **nothing**: on a Zero W it is
consistent with "the firmware loaded bootcode.bin and stopped" and with
"Linux booted fine and nothing is touching the SD card". Guessing from it
would have cost reflashes.

`scripts/card-postmortem.sh` (new this session) reads the card on the PC.
`/etc/machine-id` was committed and there were journal files, so PID 1 had
run and the whole firmware-level suspect list — including the `vc4-kms-v3d`
overlay I had confidently nominated — was dead in one line.

### Cause 1: a module that only exists at runtime

```
brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43430-sdio for chip BCM43430/1
brcmfmac: brcmf_fwvid_request_module: mod=wcc: failed 256
ieee80211 phy0: brcmf_attach: brcmf_fwvid_attach failed
```

Linux 6.6 split brcmfmac's vendor-specific code into `brcmfmac-wcc`,
`brcmfmac-bca` and `brcmfmac-cyw`. The core module attaches to the SDIO
device, reads the chip ID, decides BCM43430 is a **wcc** part, and then
`request_module()`s that one *at runtime*.

Read the first line again: `brcmf_fw_alloc_request` succeeded. The
firmware blob was fine. A missing kernel module produced an error message
that looks like a firmware problem.

**This is the bill for naming modules explicitly instead of installing
`kernel-modules`.** That decision was right and stays — it is most of the
59.4 → 45.9 MB — but the cost is precisely this: a `request_module()`
dependency resolved at runtime is invisible to every static check in
section 5. You cannot find it by reading the rootfs. Only a boot finds it.
That is a real limit of the method, discovered about two hours after
writing the method down.

### Cause 2: no regulatory database

```
platform regulatory.0: Direct firmware load for regulatory.db failed with error -2
```

`wireless-regdb-static` was missing (the files are in the `-static`
package, not the main one — the main one serves the obsolete CRDA
userspace path). Without it the kernel uses the built-in conservative
"world" domain: reduced TX power, and channels 12-13 unusable in 2.4 GHz.
`country=PL` in the wpa config has nothing to look itself up in. On a
router parked on 12 or 13 that alone prevents association.

### Cause 3: wic appends to fstab without looking

```
systemd-fstab-generator[77]: Failed to create unit file
  '/run/systemd/generator/boot.mount', as it already exists.
  Duplicate entry in '/etc/fstab'?
(sd-exec-[75]: systemd-fstab-generator failed with exit status 1.
```

Not a warning — **exit 1**, abandoning the whole fstab-to-units
translation for that boot. On the card:

```
/dev/mmcblk0p1       /boot   vfat   defaults,nofail  0  0     <- ours
/dev/mmcblk0p1	/boot	vfat	defaults	0	0             <- wic's
```

`update_fstab()` in `poky/scripts/lib/wic/plugins/imager/direct.py` loops
over every partition with a mountpoint other than `/` and appends a line,
with no check for whether that mountpoint is already present. This only
bites because we HAVE a hand-written fstab; on a stock image wic's line is
the only one, which is why it is not a known trap.

Fixed with `WIC_CREATE_EXTRA_ARGS += " --no-fstab-update"`. Note the
per-partition `--no-fstab-update` in `ksparser.py` exists but that loop
never consults it in scarthgap — the working switch is the wic
command-line option, which `image_types_wic.bbclass:73` passes through.
Keeping our fstab authoritative was the point: it documents why each line
exists and it applies to every image type, not only the `.wic`.

### And the post-mortem tool lied

It reported both provisioned files MISSING on a card that had them.
`/etc/wpa_supplicant` is 0700 and `/root` is 0700, so `[ -f ]` as an
ordinary user returns false on a path it cannot read. **A test that cannot
distinguish "absent" from "unreadable" is not a test — it is a coin flip
that lies with confidence.** Those checks run under sudo now and report
the difference explicitly.

---

## 9. It works. 22.7 s, and where the rest of it goes

First boot after the fixes:

```
Startup finished in 4.566s (kernel) + 18.093s (userspace) = 22.660s
multi-user.target reached after 17.745s in userspace.
```

Against the **86.9 s** baseline. `systemctl --failed` empty, fstab
generator silent, regulatory database loading, NTP synchronised.

Caveat on that number, caught by `journalctl --list-boots` showing a
single boot: it is a FIRST boot and still carries first-boot costs —
`dropbearkey.service` alone is 4.733 s in `systemd-analyze blame`, and it
never runs again.

### The clean second boot, and why the caveat barely mattered

```
Startup finished in 4.716s (kernel) + 17.342s (userspace) = 22.058s
multi-user.target reached after 16.988s in userspace.
```

**0.6 seconds faster.** `dropbearkey.service` and its 4.733 s are gone
from `blame` entirely, and the total moved by six hundred milliseconds.

That gap is the lesson, and it is a trap worth naming: **`systemd-analyze
blame` does not rank units by their contribution to boot time.** It ranks
them by how long each unit took to start, and on a system with any
parallelism most of those durations overlap. `dropbearkey` was 4.7 s of
wall time spent *alongside* the wait for `wlan0`, not in series with it.
Removing it freed a core that had nothing else to do.

`systemd-analyze critical-chain` is the one that answers "what is making
boot slow", and it said the same thing before and after:

```
multi-user.target @16.988s
`-wpa_supplicant@wlan0.service @16.947s
  `-sys-subsystem-net-devices-wlan0.device @16.782s
```

So the first-boot caveat was real but worth 0.6 s, and the honest
conclusion is that **the clean baseline is 22.06 s and it is essentially
all one wait.** Everything in the blame list — networkd 5.9 s, resolved
4.9 s, timesyncd 4.6 s, udev-trigger 3.4 s — is happening inside the
shadow of that wait, and shortening any of them alone changes nothing.

Corollary for the optimisation work ahead: only changes that move
`sys-subsystem-net-devices-wlan0.device` earlier can move the total.
Everything else has to be justified on footprint, SD wear or correctness
instead — which is a fine justification, but it is not boot time, and
conflating the two is how people spend a week making a boot 0.6 s faster.
(`dev-mmcblk0p2.device` did drop 10.4 s → 8.5 s between the two boots
without the total following it, which is the same lesson a second time.)

> **Corrected in session 16 — see notes/21 §4.** The corollary above is
> wrong on this board, and wrong for an instructive reason. It assumes
> off-chain work is free because it runs on another core. This board has
> one core, and measurement showed it ~97% saturated for the whole boot
> (21.4 s busy, 0.6 s idle, 0.56 s iowait). At that saturation every
> off-chain unit is stealing CPU from the chain, so removing *any* work
> moves the total roughly one-for-one. The `blame`-vs-`critical-chain`
> distinction stated above is still correct — `blame` still cannot tell
> you what is *gating*. What is wrong is the conclusion drawn from it.
> The question that should have come first: **is this boot waiting, or is
> it working?**

### The critical chain is one wait

```
multi-user.target @17.745s
`-wpa_supplicant@wlan0.service @17.699s
  `-sys-subsystem-net-devices-wlan0.device @17.632s
```

NetworkManager's 43 s is gone and dropbear is not on the chain at all —
socket activation working exactly as designed. What replaced it is the
WiFi chip appearing.

Worth being precise about what is even being measured. `systemd-analyze`
reports time to `multi-user.target`. This product is *usable* when it is
reachable over SSH and logging; the logger needs no network and dropbear's
socket opens far earlier. So the user-facing number is "time to wlan0 plus
DHCP", which is the same figure. Optimising `multi-user.target` and
optimising the product happen to coincide here — but only by accident, and
it is worth checking that assumption again after each change.

### The 17-second hole

```
[  4.260] mmc1: new high speed SDIO card at address 0001   <- chip found
                        ... 17 seconds ...
[ 21.269] brcmfmac: F1 signature read @0x18000000          <- driver probes it
[ 21.655] Firmware: BCM43430/1 wl0 ... version 7.45.98     <- blob loads in 0.4 s
[ 23.808] CTRL-EVENT-CONNECTED                             <- associated
[ 31.163] DHCPv4 address 192.168.50.34 acquired
```

The hardware is present at 4.3 s. The driver does not touch it until
21.3 s. Everything after that is quick. **Essentially the whole boot
problem is one gap in which nothing visible happens.**

What is in the gap: `cfg80211`, `brcmutil`, `brcmfmac` and
`brcmfmac-wcc` are all `=m` and all xz-compressed
(`CONFIG_MODULE_COMPRESS_XZ=y`), loaded by udev off a slow SD card and
decompressed on one 1 GHz ARM11 core. `cfg80211.ko.xz` is 223 KB
compressed on its own.

Corroborating smell: `Expecting device /dev/mmcblk0p1` at 6.9 s →
`Found device` at **17.4 s**. That is the FAT partition, trivially
present. Ten seconds for udev to reach it.

### Two things removed immediately, because they are waste rather than tuning

**busybox-syslog.** Every kernel line appears twice in the journal:

```
[21.268867] kernel:      brcmfmac: F1 signature read ...
[21.281007] kernel[181]: [21.268867] brcmfmac: F1 signature read ...
```

PID 181 is busybox klogd re-reading the ring buffer journald already read
from `/dev/kmsg`, so journald writes every kernel message to the SD card
twice. Worse than redundant: the duplicates of the 0-4 s messages arrive
at monotonic 18-19 s, so klogd spends the first eighteen seconds of boot
replaying the buffer on the only core. Present solely because
`packagegroup-core-boot` RRECOMMENDS `${VIRTUAL-RUNTIME_base-utils-syslog}`
(`default-providers.inc:31`), a default older than systemd being normal.
`systemd-journald-dev-log.socket` already provides `/dev/log`. Dropped via
`BAD_RECOMMENDATIONS`, the image-level knob for refusing an RRECOMMENDS
without editing the packagegroup that made it. (rpm and ipk only —
`rootfs_deb.bbclass:19` warns and ignores it.)

**DISABLE_VC4GRAPHICS.** No display is ever attached. Recorded plainly:
this overlay was my leading suspect for the board not booting and I was
wrong. Removing it is an optimisation on its own merits.

### Still to try, biggest first

1. `CONFIG_MODULE_COMPRESS_NONE` — cheap, low risk, pure CPU saving,
   costs rootfs size.
2. `cfg80211`/`brcmutil`/`brcmfmac` built in (`=y`) — removes udev and
   modprobe from the path entirely; the chip would probe during kernel
   init right after `mmc1` appears at 4.3 s. **Caveat stated up front: a
   built-in brcmfmac requests firmware during kernel init, possibly before
   the rootfs is mounted.** It uses the async firmware API and normally
   copes, but "normally" is not "verified", and the fallback is
   `CONFIG_EXTRA_FIRMWARE` or an initramfs, both of which cost more than
   they look. Hence #1 first.
3. **DHCP took 7.4 s** (carrier 23.8 → address 31.2) — about a third of
   the remaining budget, and completely uninvestigated.

These are deliberately not bundled together. Each gets measured on its
own, or we learn a total and not a cause.

### Two observations, neither urgent

The AP overrides our regulatory domain: `alpha2=PL` from our config, then
`init=COUNTRY_IE type=COUNTRY alpha2=DE` from the router's beacon. So
`country=` in the wpa config is not the final word.

`timedatectl` reports synchronised with NTP active, so the missing RTC
self-corrects once the network is up. Log filenames created before that
still carry a bogus date — the journal pulled off the card was stamped
May 2025 for exactly this reason. A real design question for the logger,
not yet answered.

---

## Next

1. **Reflash with the busybox-syslog and vc4 removals and re-measure.**
   The clean pre-change baseline is 22.058 s; judge those two against it.
   Expect little or nothing on the total — neither is on the critical
   chain — and that is the point of measuring rather than assuming.
2. **Attack the 17-second hole**, one change at a time so each has a
   measured value: module compression off, then the WiFi stack built into
   the kernel. Then look at the 7.4 s DHCP, which nobody has examined.
3. **The logger has never been exercised on this board.** Everything so
   far is OS bring-up. Plug the Debugprobe into the data port and confirm
   the udev rule fires, the template instantiates, and a file appears
   under `/var/log/serial-logger/`. It works on the Pi 5 (notes/19); it
   has not been shown to work here.
4. **Remaining levers, still wanting a number first:**
   - the `rauc` DISTRO_FEATURE still adds dm-verity/squashfs/loop/nbd to a
     kernel on a board with no A/B layout
   - poky's desktop `DISTRO_FEATURES` (`libx11`, `libxcb`,
     `kbd-consolefonts`, `keymaps`) on a board with no display
   - `systemd-networkd-wait-online.service` is enabled; nothing should be
     pulling `network-online.target`, but confirm
   - journald `SystemMaxUse=` — the journal is persistent now
   - a static IP, or at least a DHCP reservation on the router
   - `systemd-analyze` comes back out of the image once measuring is done
   - `DISTRO_CODENAME` still says "rpi5-era" on a Zero W
5. **Read-only rootfs** (checkbox 6). This is where the persistent-log
   decision gets revisited properly: a separate data partition answers
   read-only rootfs and log durability with one change.

### The confound to keep in mind

The SD card is one the user had already retired as unreliable on a Pi 4B,
kept only because no other card was to hand. It has already produced one
0.2 W dead boot that a re-seat fixed. `dev-mmcblk0p2.device` taking 10.4 s
and udev needing 10 s to notice the FAT partition are both consistent with
a slow or marginal card as much as with a slow CPU. **Before concluding
anything about I/O timing, retest on a known-good card.** No amount of
config bisection out-argues flaky media.

## State things were left in

- **The Zero W now runs Yocto.** Flashed, provisioned, on WiFi at
  192.168.50.34, reachable over SSH as root with `~/.ssh/pi_zero_key`.
  **22.058 s clean second boot** (4.72 kernel + 17.34 userspace) vs the
  86.9 s Raspberry Pi OS baseline. That is the number to beat from here.
- Raspberry Pi OS Lite is off the board. Rollback for the whole capstone
  is still one `dd` away:
  `/media/blankmcu/EmbeddedLinux/backups/rpi0-pios-lite-2026-08-17.img.gz`.
- The image in the build dir is one rebuild AHEAD of what is on the card —
  it now has `BAD_RECOMMENDATIONS += "busybox-syslog"` and
  `DISABLE_VC4GRAPHICS = "1"`, neither of which has been flashed or
  measured.
- `~/.rpi0-secrets/wpa_supplicant-wlan0.conf` exists and works. It is
  outside the repo and stays there.
- `~/.ssh/config`'s `Host rpi0` entry now works (`ssh rpi0`). The IP in it
  is a DHCP lease and will drift — a router reservation is the cheap fix.
- The serial logger itself has **not been exercised on this board yet.**
