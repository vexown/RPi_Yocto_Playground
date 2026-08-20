# Session 16 — Is the boot waiting, or working?

Session 15 got the Zero W booting its own Yocto image in 22.058 s, down
from 86.9 s on Raspberry Pi OS, and left behind a "17-second hole" between
the WiFi chip appearing on the SDIO bus and the driver talking to it. The
plan going in was to attack that hole with the list from notes/20 §"Still
to try": module compression first, then building the WiFi stack into the
kernel.

That plan was wrong, and finding out why took one evening, three killed
hypotheses (one of them invented and killed inside ten minutes), zero
rebuilds, and one `cat /proc/stat`.

The lesson of the session is a question that should be asked *before* any
boot-time optimisation, and that I did not ask for two sessions:

> **Is this boot waiting, or is it working?**

Everything else here follows from the answer.

---

## 1. Two clocks that are not the same clock

Before any of the analysis, a correction to something asserted in
notes/20. These two numbers were being compared as though they shared an
origin:

```
journalctl -o short-monotonic:   [   21.269] brcmfmac: F1 signature read ...
systemd-analyze critical-chain:  sys-subsystem-net-devices-wlan0.device @16.782s
```

They do not.

- **`short-monotonic` timestamps are offsets from `CLOCK_MONOTONIC` zero** —
  the moment the kernel started counting, near the top of kernel boot.
- **`systemd-analyze`'s `@` times are offsets from the start of
  userspace** — i.e. from the moment `/sbin/init` was exec'd.

To compare them you add the kernel time that `systemd-analyze` reports
separately. For that boot: `4.716 + 16.782 = 21.498`, against a
`brcmfmac` probe at `21.269`. Not "roughly consistent" — the same event.

Checked again on a later boot, `4.561 + 16.890 = 21.451`, with the udev
worker touching the new netdev at `21.190`. Same event again.

This matters more than a units nitpick. Comparing the two scales directly
makes the userspace half of the boot look ~4.5 s shorter than it is, and
that is exactly the size of the gaps people go hunting for.

---

## 2. The 17-second hole is four holes

Reading the whole kernel + systemd log in monotonic time, rather than
grepping for `brcm`, breaks the "hole" into pieces that want different
answers:

| from | to | duration | what is happening |
|------|------|----------|-------------------|
| 0 | 4.32 | 4.3 s | kernel |
| 4.32 | 11.25 | **6.9 s** | `/sbin/init` starts → `systemd-udevd` starts |
| 11.25 | 12.45 | 1.2 s | udevd itself starting |
| 12.45 | 17.31 | **4.9 s** | coldplug queue, before `cfg80211` is reached |
| 17.31 | 20.57 | 3.3 s | WiFi module chain + SDIO probe + firmware |
| 20.57 | 21.19 | 0.6 s | `wlan0` netdev appears |

The module load — the thing two sessions of notes had been blaming — is
at most the 3.3 s row. The single largest block, 6.9 s, happens **before
udev has started at all**, so no amount of module tuning can touch it.

Grepping for the subsystem you suspect will always show you a story about
that subsystem. Reading the whole window shows you the shape of the boot.

---

## 3. Three hypotheses, killed without a rebuild

### Module compression: worth 0.15 s

`CONFIG_MODULE_COMPRESS_XZ=y` is set, and `cfg80211.ko.xz` is 223 KB, so
"xz decompression on a 1 GHz ARM11" sounded plausible enough to sit at
the top of the list. Measured on the target:

```
xz decompress, WARM cache (pure CPU)   real 0m 0.15s
same file, COLD cache, read only       real 0m 0.03s
```

The entire four-module WiFi chain costs about 0.2 s including reading it
off the card. `CONFIG_MODULE_COMPRESS_NONE` would have been a kernel
rebuild for a fifth of a second. Struck.

Also learned in passing: `# CONFIG_MODULE_DECOMPRESS is not set`, so the
kernel cannot accept compressed modules directly and kmod decompresses in
userspace before `init_module`. Which of the two does the work doesn't
change the number, but it's worth knowing which knob is which.

### The console: killed ten minutes after being invented

Inside the 6.9 s block, every trivial systemd operation is ~40 ms apart:

```
[    6.666] Created slice Slice /system/getty.
[    6.705] Created slice Slice /system/modprobe.
[    6.745] Created slice Slice /system/serial-getty.
```

Forty milliseconds to create a cgroup is absurd, and before journald
starts (9.82 s) systemd writes every line to the consoles. A blocking
115200 UART plus an unaccelerated framebuffer console would explain it
neatly — and would have made `DISABLE_VC4GRAPHICS`, already built but not
flashed, unexpectedly valuable.

It was wrong:

```
=== consoles actually active ===   ttyS0
=== framebuffer ===                none
```

One console, the UART, and no framebuffer at all — `cmdline.txt` never
contained `console=tty1`. A ~50-character line at 115200 8N1 costs about
4 ms, an eighth of the observed cadence. The vc4 change went back to
being what it was originally justified as: footprint, not speed.

Worth recording because of how it happened. The 40 ms cadence was a real
observation, the mechanism was a plausible story, and the story was
checkable in one command. **Stories about mechanism are free; check them
before you build anything on them.**

### The SD card: not the throughput

The card is one previously retired as unreliable, and notes/20 flagged it
as an open confound. On sequential reads it is fine:

```
dd if=/dev/mmcblk0 of=/dev/null bs=1M count=16   →   16 MB in 0.76 s = 21 MB/s
```

That is about the ceiling for the Zero W's SDIO bus. This does not clear
the card of reliability problems or of random-I/O weakness, but it does
remove "slow card" as an explanation for a 22-second boot.

---

## 4. The measurement that actually mattered

All three of those were guesses about *which* work was expensive. The
question underneath them — is there expensive work at all, or is the boot
sitting idle waiting for something? — is answered by two files and no
rebuild.

`/proc/stat`'s first line is cumulative since boot, in 1/100 s:

```
cpu  user nice system idle iowait irq softirq ...
```

So: reboot, get in over SSH as early as possible, and read the counters
before the machine has had time to accumulate much idle.

```
$ ssh rpi0 'reboot'
$ until ssh -o ConnectTimeout=2 rpi0 true 2>/dev/null; do :; done
$ ssh rpi0 'cat /proc/uptime; head -n 1 /proc/stat; systemd-analyze'
33.60 11.22
cpu  1141 0 984 1122 56 0 16 0 0 0
Startup finished in 4.566s (kernel) + 17.379s (userspace) = 21.946s
```

Arithmetic:

```
total   = 1141 + 984 + 1122 + 56 + 16     = 3319 jiffies = 33.19 s   (matches uptime)
busy    = user 1141 + system 984 + softirq 16 = 2141    = 21.41 s
idle    = idle 1122 + iowait 56           = 1178        = 11.78 s
```

The boot finished at 21.95 s and the sample was taken at 33.60 s, so
11.65 s of that idle belongs to an idle machine sitting there afterwards
with one SSH session on it. Which leaves, for the boot itself:

| | during the ~22 s boot |
|---|---|
| busy | **~21.4 s** |
| idle + iowait | **~0.6 s** |

**The core is ~97% saturated for the entire boot, and total `iowait` is
0.56 s.** This board is not waiting on the SD card, not waiting on a probe
timeout, not waiting on the network. It is computing, flat out, for
twenty-two seconds.

Also notable: `system` 9.84 s against `user` 11.41 s. Forty-six percent of
the boot is kernel time — udev, module insertion, cgroup manipulation,
journald writes.

### Why this reframes the last two sessions

notes/20 recorded, correctly, that `systemd-analyze blame` ranks units by
their own start duration and only `critical-chain` says what is delaying
the finish. From that it drew the corollary:

> only changes that move `sys-subsystem-net-devices-wlan0.device` earlier
> can move the total; everything else must be justified on footprint, SD
> wear or correctness instead.

**That corollary is wrong on a single-core machine, and this board has one
core.** The reasoning behind it assumes off-chain work is free because it
runs somewhere else. There is no somewhere else. Every off-chain unit is
competing for the only execution resource the chain also needs. At 97%
saturation, removing *any* CPU work moves the finish line roughly
one-for-one.

The `blame`-vs-`critical-chain` distinction is still true and still
important — `blame` still cannot tell you *what is gating*. What changes
is the conclusion drawn from it. On a multi-core box, off-chain work is
nearly free. On one core, `blame` is a decent proxy for "CPU stolen from
the chain."

So the rule is not "trust critical-chain, ignore blame". It is:

> **Establish whether the boot is wait-bound or work-bound first. That
> answer decides which tool's output means anything.**

---

## 5. A null result that was still conclusive

The governor looked like a free win:

```
scaling_governor  ondemand
scaling_min_freq  700000
scaling_max_freq  1000000
```

`ondemand` ramps *after* observing load. On a boot that is pinned from the
first instant, that ramp latency is pure loss, and 1000/700 = 1.43× on
everything CPU-bound. `force_turbo=1` in `config.txt` locks the ARM, core
and SDRAM clocks at maximum (and with `over_voltage=0` it does not set the
OTP warranty bit). One file edit, one reboot, no rebuild.

Result:

```
min=1000000 max=1000000 cur=1000000
29.32 6.90
cpu  1142 0 996 690 57 0 5 0 0 0
Startup finished in 4.561s (kernel) + 17.469s (userspace) = 22.030s
```

21.946 s → 22.030 s. Nothing.

The interesting part is not the total, it is the jiffies:

```
before force_turbo:  busy = 1141 + 984 + 16 = 21.41 s
after  force_turbo:  busy = 1142 + 996 +  5 = 21.43 s
```

**Jiffies are wall-clock accounting.** If the clock had really gone from
700 to 1000 MHz, the same work would have taken *fewer* busy jiffies. It
took the same, to within 0.1%. The only explanation is that the CPU was
already at 1000 MHz throughout the boot — which makes sense once stated:
`ondemand` had a core at 97% load from its very first sample and nothing
to hesitate about.

A second confirmation fell out of the two samples being taken at
different uptimes:

```
sample at 33.60 s uptime:  busy 21.41 s   idle 11.78 s
sample at 29.32 s uptime:  busy 21.43 s   idle  7.47 s
sample time differs by 4.28 s;  idle differs by 4.31 s;  busy differs by 0.02 s
```

Idle tracked the sample time exactly and busy did not move at all. That is
about as clean a demonstration as you get that the 21.4 s of busy time is
*entirely* boot work, and that it is invariant to the clock experiment.

`force_turbo` was rolled back — it buys nothing and costs power.

**A negative result is only wasted if you don't read it.** This one killed
clock speed as a lever *and* independently re-confirmed the saturation
measurement.

---

## 6. The four levers

Given a boot that is **work-bound on one core**, there are exactly four
things you can do. Only the first is what people usually mean by
"optimising the boot".

### 1. Do less

Remove work outright. Fewer units, fewer packages, fewer kernel modules
for udev to walk, fewer log lines to write. Directly reduces the 21.4 s.

Candidates here: `busybox-syslog` (klogd re-reads the kernel ring buffer
journald already consumed, and double-writes every line to SD),
`systemd-resolved` and `systemd-timesyncd` (4.9 s and 4.6 s of `blame`),
the `rauc` DISTRO_FEATURE dragging dm-verity/squashfs/loop/nbd into a
kernel on a board with no A/B layout, and poky's desktop
`DISTRO_FEATURES` on a headless board. This image loads **102 units out
of 197 installed unit files**.

### 2. Do it cheaper

Same function, less computation. Journald's `Audit=no` instead of
collecting audit records. `busybox` implementations instead of full
GNU ones. A compiled-in driver instead of a module load. Static
configuration instead of a discovery protocol.

### 3. Do it later

Work that isn't needed *before the goal* can be ordered after it. It
still happens; it just stops competing for the core during the window
that counts. Socket and path activation are this lever in its purest
form — dropbear is already socket-activated on this image and therefore
never appears on the critical chain.

### 4. Do it first

This is the one that does not occur to you until you have the saturation
number. It is also the one that is easiest to misjudge, because whether it
is worth anything at all depends entirely on **which clock you are reading**.

**"Boot time" is not one number.** There are at least two, and they behave
in opposite ways:

| clock | what it measures | effect of lever 4 |
|---|---|---|
| time-to-all-work-done | what `systemd-analyze` prints: when the **last** unit in the boot transaction finishes | **exactly zero, always** |
| time-to-goal | when the device does the job it was built for — here, `wlan0` has an IP and the logger can ship data | **the strongest lever available** |

On a saturated core, time-to-all-work-done *is* total work W. Reordering
conserves W. So lever 4 cannot move that number by a millisecond, and any
experiment graded on it will report lever 4 as a failure.

Time-to-goal is a different quantity entirely:

```
time-to-goal = work(the goal's dependencies)
             + work scheduled ahead of the goal that the goal does not need
```

That second term is pure waste, and deleting it is exactly what lever 4
does.

> One cashier, a hundred items in the queue. The queue empties at the same
> moment no matter what order you ring things up — that is W, and it is
> fixed. But if you only care about *your* item, being served first instead
> of ninety-ninth is the whole game. Lever 4 does not shorten the queue.
> It moves you to the front of it.

Levers 1–3 shrink the pie. Lever 4 changes which slice you eat first, and
costs nothing at all — but only the second clock can see it.

**On this image**, before the change, `multi-user.target` waited on exactly
one thing:

```
multi-user.target @17.094s
`-wpa_supplicant@wlan0.service @17.052s
  `-sys-subsystem-net-devices-wlan0.device @16.890s
```

`wlan0` does not exist until `brcmfmac` probes. Everything else the core
does before that is, from the goal's point of view, in the way.

> **Corrected in session 17 — see notes/22.** Where this box now stands,
> the note used to claim: *"even at constant total work, moving the chain to
> the front of the queue moves the finish."* That is true of time-to-goal
> and **false** of `systemd-analyze`'s finish line, and the original text
> conflated the two — which is the whole reason lever 4 looked like a null
> result when it was measured.
>
> The data settled it. `10-wifi-early.conf` moved `wlan0.device` from
> 21.50 s to **14.24 s** monotonic and removed it from the critical chain
> altogether. The printed total moved 0.616 s, **all** of which is
> attributable to the two lever-1 changes shipped alongside it (`vc4` and
> `busybox-syslog`, both confirmed absent from the kernel log).
>
> Lever 4 worked exactly as designed, and scored zero on the wrong exam.

---

## 7. The empty slot

Lever 4 had somewhere obvious to go. From the boot log:

```
[    4.232] mmc1: new high speed SDIO card at address 0001
[    8.292] systemd[1]: Load Kernel Modules was skipped because no trigger
                        condition checks were met.
...
[   17.311] cfg80211: Loading compiled-in X.509 certificates for regulatory database
[   20.575] brcmfmac: F1 signature read @0x18000000=0x1541a9a6
```

`systemd-modules-load.service` runs at **8.3 s** and does nothing, because
the image ships no `modules-load.d` configuration at all. So `brcmfmac`
is left to udev, which loads it on demand from the coldplug queue — and
it waits its turn behind every other device on the board until **17.3 s**.

The radio was sitting on the bus, enumerated and ready, for thirteen
seconds, next to an early-boot service whose entire job is to load modules
and which was idling because nobody had told it to.

The fix is one file:

```
meta-playground/recipes-connectivity/rpi0-network/files/10-wifi-early.conf
```

containing, after the explanation, the single line `brcmfmac`. Installed
to `${nonarch_libdir}/modules-load.d/` — the vendor directory, for the
same reason the preset and the `DefaultInstance` drop-in live there: it is
a statement by the image about how it wants to boot, not a policy chosen
by the operator of one particular box. `/etc/modules-load.d` is read
first, so an admin who disagrees can shadow it and win.

`${nonarch_libdir}` rather than `${libdir}` because on a multilib build
`${libdir}` can become `/usr/lib64`, and systemd looks in `/usr/lib`
regardless of word size. Configuration is not architecture-specific and
must not follow the library path.

Only `brcmfmac` is named. `cfg80211` and `brcmutil` come along via
`modules.dep`. `brcmfmac-wcc` is deliberately absent: it is not a
`modules.dep` dependency, it is `request_module()`d at runtime by
`brcmf_fwvid` once the chip ID has been read off the bus and BCM43430
resolved to the "wcc" vendor. That is the same runtime-only dependency
whose absence cost a whole flash cycle in notes/20 §8, and it cannot be
usefully pre-empted from here.

### What it does not do, and what it costs

It removes **zero** CPU work. Whatever udev was doing during those
thirteen seconds still has to happen; it now happens after the WiFi stack
instead of before it. This is lever 4, not lever 1.

And it has a real cost. `systemd-modules-load.service` is synchronous and
`sysinit.target` waits for it. Registering an SDIO driver probes any
already-present matching device in the same call, and that probe downloads
firmware to the chip — 1–2 s on this hardware. So `sysinit.target` and
everything ordered after it moves *later* by roughly that much.

The bet is that pulling `wlan0` forward by ~9 s beats pushing `sysinit`
back by ~2 s. It is a bet, and the reflash settles it.

---

## 8. The noise floor

Four boots of the unchanged image were measured this session:

```
22.058 s   (4.716 + 17.342)   previous session, clean second boot
21.989 s   (4.656 + 17.333)
21.946 s   (4.566 + 17.379)
22.030 s   (4.561 + 17.469)   with force_turbo=1
```

Spread: 0.112 s. **Any claimed improvement smaller than about 0.15 s is
not measurable on this setup** and should not be believed without
repeated boots. Worth writing down before the next round of changes, so
that a 0.1 s "win" doesn't get recorded as a win.

---

## 9. What went into the next image

Three changes, flashed together:

| change | lever | expected |
|--------|-------|----------|
| `10-wifi-early.conf` | **4 — do it first** | the real bet: `wlan0` ~9 s earlier |
| `BAD_RECOMMENDATIONS += "busybox-syslog"` | 1 — do less | small, but now plausibly real |
| `DISABLE_VC4GRAPHICS = "1"` | 1 — do less | small; mostly footprint |

The latter two were already built and committed in session 15 but never
flashed.

Bundling three changes into one measurement is normally poor experimental
hygiene, and notes/20 explicitly said not to. It is acceptable here only
because each change leaves a **distinct signature in the kernel log**, so
attribution survives the bundling:

- `cfg80211` appearing at ~8 s instead of ~17 s → the reorder worked
- no `vc4-drm soc:gpu: bound ...` lines → the vc4 change took effect
- no klogd ring-buffer replay in the first ~18 s → busybox-syslog is gone

If the total does not move, the timeline still says which of the three did
what it was told and simply didn't matter. That is a different and more
useful failure than "we changed three things and nothing happened".

---

## The method, stated once

For any boot-time work on any board:

1. **Ask whether the boot is waiting or working.** `/proc/stat` sampled
   right after boot, `idle + iowait` against uptime. Two files, no
   rebuild, and the answer decides everything downstream.
2. **If it is waiting**, the levers are timeouts, dependency ordering,
   parallelism, faster storage. `critical-chain` is the tool and `blame`
   is mostly noise.
3. **If it is working**, the levers are the four above. On a multi-core
   box, prefer 1 and 2. On a single core, 3 and 4 become just as
   powerful, and `blame` becomes a reasonable proxy for stolen CPU.
4. **Read the whole timeline in one clock**, not a grep for the subsystem
   you suspect. Add the kernel time before comparing `systemd-analyze`'s
   `@` offsets to journal monotonic timestamps.
5. **Establish the noise floor** before believing any improvement.
6. **Check mechanism stories with a command before building on them.**
   The console theory in §3 took ten minutes to invent and one `cat` to
   destroy; had it gone unchecked it would have justified a rebuild.

---

## Next

1. **Measure the three-change image** against the 21.946–22.058 s
   baseline, and use the kernel timeline to attribute the result.
2. **If the reorder worked**, the next bottleneck is whatever `wlan0` now
   waits behind, and the timeline will name it. If it did not, find out
   whether `brcmfmac` actually loaded at 8 s — if it did and the total
   held, then queue position was never the cause and lever 1 is all
   that's left.
3. **The 7.4 s DHCP** (carrier → address) is still completely
   uninvestigated and is about a third of the remaining budget.
4. **Lever 1, in order of expected size:** journald `Audit=no`; drop
   `systemd-resolved` (let networkd write `/etc/resolv.conf`); drop
   `systemd-timesyncd`; the `rauc` DISTRO_FEATURE; poky's desktop
   `DISTRO_FEATURES`. Each one measured on its own — the bundling in §9
   was a one-off justified by distinguishable signatures, not a new
   policy.
5. **The logger has still never been exercised on this board.** Every
   session so far has been OS bring-up. Plug the Debugprobe into the data
   port and confirm the udev rule fires, the template instantiates, and a
   file appears under `/var/log/serial-logger/`.
6. **The card confound is narrowed, not closed.** 21 MB/s sequential is
   fine; random I/O and reliability are untested, and this is still a card
   retired from a Pi 4B for being flaky.

## 10. The flash that wasn't

The reflash did not happen. The board came up blinking and never appeared
on the router, and the post-mortem said why in its first four lines:

```
--- config.txt (non-comment lines) ---
    dtoverlay=vc4-kms-v3d
    dtparam=act_led_trigger=heartbeat
    dtoverlay=playground-led
--- kernel present? ---
    /media/blankmcu/boot/kernel_2712.img
```

`kernel_2712.img` is a BCM2712 kernel and `rootfs_A` is a RAUC A/B label.
The Zero W's card had **the Pi 5's `playground-image`** on it. An ARMv6
board never finds a kernel it can run, so userspace never starts, so there
is no journal and no wifi. The blinking LED was a firmware error pattern,
not the heartbeat trigger that config.txt asks for.

Cause, and it was mine:

```sh
case "${2:-}" in
    rpi0)  TARGET="rpi0"; IMAGE_NAME="${3:-rpi0-logger-image}" ;;
    rpi5)  TARGET="rpi5"; IMAGE_NAME="${3:-playground-image}" ;;
    ""|*)  TARGET="rpi5"; IMAGE_NAME="${2:-playground-image}" ;;   # <-- this
esac
```

`flash-sd.sh` defaulted its target. Omit the word `rpi0` and it silently
chose a board for you and wrote 45 MB of it to a raw block device.

That default was written in session 15, when it was harmless: there was
one board. **A convenience default is only a convenience while there is
one possible answer.** The moment the second target existed, the default
stopped being a shortcut and became a way to flash the wrong image without
being told. The target is now mandatory and the script refuses without it.

### The post-mortem tool lied again, the same way as last time

Section 2 of the report said:

```
/etc/machine-id: EMPTY -> systemd did not get far enough to commit one
/var/log is a: SYMLINK (volatile! VOLATILE_LOG_DIR did not take)
```

Both statements are confident, plausible, and about the wrong image.
`playground-image` has no `VOLATILE_LOG_DIR = "no"`, so a volatile
`/var/log` is exactly correct there — the tool reported a *setting we
never applied to this image* as a *setting that failed*.

This is the second time this script has done this. In notes/20 §8 it
reported both provisioned files MISSING because it could not read inside
0700 directories, and the lesson recorded then was: *a test that cannot
distinguish "absent" from "unreadable" is a coin flip that lies with
confidence.* The same lesson, one level up: **a diagnostic that does not
first establish what it is looking at is not diagnosing, it is
pattern-matching against an assumption.**

Fixed by making section 2 open with the image's identity before any
judgement:

```
--- which image is on this card? ---
    version: 0.3
    Playground 0.3 (rpi5-era)
    boot partition carries: kernel_2712.img
    !!! no plain kernel.img -- this is NOT an ARMv6 (Pi Zero/Pi 1) image
```

The kernel filename is the check that matters, because the firmware picks
it by SoC: `kernel.img` is ARMv6, `kernel_2712.img` is a Pi 5. If that is
wrong for the board in your hand, nothing else in the report means
anything.

Small irony worth keeping: `DISTRO_CODENAME` still says `rpi5-era`, a nit
sitting unfixed on notes/20's list since session 15, and it is the line
that names the culprit fastest.

---

## State things were left in

- Zero W on WiFi at 192.168.50.34, SSH as root with `~/.ssh/pi_zero_key`.
- `force_turbo=1` added to `/boot/config.txt` as an experiment and rolled
  back; `/boot/config.txt.bak` restored over it.
- Baseline to beat: **21.946 s**, noise floor ±0.11 s.
- Build directory carries three changes, **built and verified in the
  rootfs but NOT yet flashed** — the flash went to the wrong image. The
  artifacts were checked before flashing and all three are correct:
  `/usr/lib/modules-load.d/10-wifi-early.conf` contains `brcmfmac`, no
  `syslogd`/`klogd` in the 113-package manifest, and `config.txt` is down
  to `enable_uart=1` with the vc4 overlay gone.
- **The Zero W's card currently holds the Pi 5 image and must be
  reflashed**, with the target spelled out:
  `./scripts/flash-sd.sh /dev/sdX rpi0` then
  `./scripts/provision-card.sh /dev/sdX`. Then boot twice and measure the
  second boot.
- `flash-sd.sh` now requires the target argument; `card-postmortem.sh` now
  identifies the image before diagnosing it.
