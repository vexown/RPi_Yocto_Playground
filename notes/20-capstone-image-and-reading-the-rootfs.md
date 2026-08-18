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

## Next

1. **Flash and provision.** `./scripts/flash-sd.sh /dev/sdX rpi0`, then
   `./scripts/provision-card.sh /dev/sdX`. The PSK and SSH key come from
   `~/.rpi0-secrets/`, outside this public repo; the script refuses to run
   if `SECRETS_DIR` points inside it.
2. **First boot: does it come up on WiFi, and how fast?** That is the
   capstone's headline number against the 86.9 s baseline.
   If it does not appear on the LAN, the card is the debugger — mount p2
   and read `/var/log/journal` offline.
3. **Measure, then optimize** (checkbox 5). Levers identified and
   deliberately not yet pulled, all of them wanting a number first:
   - `dtoverlay=vc4-kms-v3d` is in config.txt on a headless board
   - the `rauc` DISTRO_FEATURE still adds dm-verity/squashfs/loop/nbd to a
     kernel on a board with no A/B layout
   - poky's desktop `DISTRO_FEATURES` (`libx11`, `libxcb`,
     `kbd-consolefonts`, `keymaps`) on a board with no display
   - `systemd-networkd-wait-online.service` is enabled; nothing should be
     pulling `network-online.target`, but confirm
   - journald `SystemMaxUse=`
   - static IP instead of DHCP
   - `systemd-analyze` comes back out of the image once measuring is done
4. **Read-only rootfs** (checkbox 6). This is where the persistent-log
   decision gets revisited properly: a separate data partition answers
   read-only rootfs and log durability with one change.

## State things were left in

- `rpi0-logger-image` built for `raspberrypi0-wifi`, **never flashed**.
  45.9 MB compressed, 112 packages.
- The deployed Zero W still runs Raspberry Pi OS Lite, untouched apart
  from the SSH key added in session 14. Still crash-looping deliberately.
- Rollback point for the whole capstone remains
  `/media/blankmcu/EmbeddedLinux/backups/rpi0-pios-lite-2026-08-17.img.gz`.
- `~/.rpi0-secrets/wpa_supplicant-wlan0.conf` does **not exist yet** —
  `provision-card.sh` prints the exact commands to create it on first run.
