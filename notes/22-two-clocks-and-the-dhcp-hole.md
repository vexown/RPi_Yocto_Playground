# Session 17 — Two clocks, and the nine seconds after the finish line

Session 16 ended with three changes built into `rpi0-logger-image` but
never actually booted, because `flash-sd.sh` had written the *Pi 5* image
to the Zero W's card (notes/21 §10). This session flashed the right image,
measured it, and found that the headline number we had been optimising for
two sessions is not the number that matters.

Baseline to beat: **22.006 s mean**, noise floor **±0.112 s** (notes/21 §8).

---

## 1. The result, and it is real

Three boots of the new image:

| boot | kernel | userspace | total |
|---|---|---|---|
| power-on | 4.538 s | 16.929 s | 21.467 s |
| `reboot`  | 4.419 s | 16.941 s | 21.360 s |
| power-on | 4.453 s | 16.888 s | 21.342 s |

| | baseline | now |
|---|---|---|
| samples | 22.058 / 21.989 / 21.946 / 22.030 | 21.467 / 21.360 / 21.342 |
| **mean** | **22.006 s** | **21.390 s** |
| spread | 0.112 s | 0.125 s |

**Δ = 0.616 s**, about 5.5× the noise floor.

The two spreads are near-identical. That matters more than it looks: we
moved the mean without moving the variance, which is what you want to see
before you believe a delta. A change that also inflates the spread is
usually a change that introduced a race, not a saving.

### A free result: reboot and power-on are the same boot

21.360 s (`reboot`) against 21.342 s (power-on) — inside each other's
noise. Worth having established once, because it retires a variable we
would otherwise have had to control for in every future measurement. The
firmware stage is not measurably cheaper on a warm SoC.

---

## 2. Attribution: which of the three changes bought the 0.616 s?

Three changes shipped together (notes/21 §9), so they were attributed by
signature rather than by re-measuring each one alone.

| change | signature | result |
|---|---|---|
| `DISABLE_VC4GRAPHICS` | `dmesg \| grep -ci vc4` | **0** — driver never probes |
| drop `busybox-syslog` | `dmesg \| grep -ciE 'klogd\|syslogd'`, `pidof syslogd klogd` | **0**, no daemon |
| `10-wifi-early.conf` | where `cfg80211` appears in the kernel log | **9.391 s** (was 17.31 s) |

The first two are lever 1 — they delete real work, so they move the
printed total. The third is lever 4 — it deletes **no** work at all, so
by construction it cannot move the printed total (notes/21 §6, corrected).

**Therefore the whole 0.616 s belongs to vc4 and syslog.** The module
reorder contributed exactly nothing to that number, and was never going
to.

---

## 3. What the reorder actually did

```
[  9.391414] cfg80211: Loading compiled-in X.509 certificates for regulatory database
[ 10.201759] brcmfmac: F1 signature read @0x18000000=0x1541a9a6
[ 10.227271] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43430-sdio for chip BCM43430/1
[ 10.791639] brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM43430/1 wl0: ... version 7.45.98
```

| | before | after |
|---|---|---|
| `cfg80211` loaded | 17.31 s | **9.39 s** |
| `brcmfmac` F1 signature read | 21.27 s | **10.20 s** |
| `wlan0.device` found by systemd | 21.50 s | **14.24 s** |
| on the critical chain? | **yes — it was the gate** | **absent** |

Session 16's critical chain had
`sys-subsystem-net-devices-wlan0.device @16.782s` sitting in it as the
thing everything else waited on. It is not in the output any more:

```
multi-user.target @16.128s
`-systemd-logind.service @14.277s +1.732s
  `-basic.target @13.747s
    `-sockets.target @13.717s
      `-dropbear.socket @13.672s
        `-sysinit.target @13.497s
```

The wait for the WiFi device to exist has been designed out of the boot.
That was the entire purpose of `10-wifi-early.conf` and it succeeded. The
0.616 s was simply never where the evidence lived.

### The honest cost, which the file's comments predicted

```
2.188s systemd-modules-load.service
```

It used to be ~0 s, because it was skipped for want of a config file. That
2.188 s is not new work — it is the module load plus the SDIO firmware push
relocated into `sysinit.target`, where it is now synchronous and everything
waits on it. Exactly the trade the recipe comments warned about.

---

## 4. The number that matters is 30.5 s, not 21.4 s

```
21.221842  wlan0: Gained carrier
30.512120  wlan0: DHCPv4 address 192.168.50.34/24, gateway 192.168.50.1 acquired
```

`systemd-analyze` declares victory at 21.47 s. **The device is not
reachable until 30.5 s.** Nine seconds of the user-visible boot — 30% of
it — happen after the finish line we spent two sessions moving.

And these nine seconds are a different *kind* of second. The 0 → 21 s
window is work-bound at ~97% saturation (notes/21 §4). DHCP is a **wait**.
The levers for the two halves are unrelated, and lumping them into one
number is what hid the second half for two sessions.

Also worth seeing, from the same timeline:

```
18.870209  Reached target Network
21.221842  wlan0: Gained carrier
30.512120  wlan0: DHCPv4 address ... acquired
```

`network.target` fires 2.4 s before there is a carrier and 11.6 s before
there is an address. It has never meant "the network works" — it means
"the units that configure networking have been started".

### The DHCP window is opaque at default log level

```
[ 13.374850] Starting Network Configuration...
[ 17.570209] lo: Link UP
[ 17.681545] Started Network Configuration.
[ 17.714719] wlan0: Configuring with /etc/systemd/network/20-wlan0.network.
[ 17.942491] wlan0: Link UP
[ 21.208820] wlan0: Connected WiFi access point: StatekMatka_V2
[ 21.221842] wlan0: Gained carrier
[ 30.512120] wlan0: DHCPv4 address 192.168.50.34/24 ... acquired
```

Nine seconds, one blank line. Ruled out cheaply before spending anything
on it: `20-wlan0.network` sets `LinkLocalAddressing=no` and `DHCP=ipv4`,
so there is no IPv6 RA, no DAD, and no link-local fallback hiding in the
gap. Whatever it is, it is inside DHCPv4.

The two candidate shapes, which need debug logging to tell apart:

1. **DISCOVER goes out at ~21.3 s and the answer arrives at ~30.4 s.**
   The router is slow, and the interesting question becomes *why for this
   client* — systemd-networkd's default `ClientIdentifier=duid` derives
   the DUID from `/etc/machine-id`, which is regenerated on every reflash,
   so the AP sees an unknown client each time.
2. **DISCOVER does not go out until ~29 s.** Then it is networkd's own
   retry/backoff timing, or something upstream of it, and the router is
   innocent.

These have completely different fixes, and no amount of staring at the
default-level log distinguishes them.

---

## 5. A non-result, recorded so it is not chased again

One `/proc/stat` sample showed `nice 387` (3.87 s at positive nice
priority) where every previous sample had `nice 0`. It did not reproduce:
the next coherent sample was

```
614.56 578.36                              # /proc/uptime
cpu  1959 0 1421 57836 59 0 24             # nice = 0
```

and a sweep of `/proc/*/stat` found positive-nice processes nowhere — only
kernel threads at nice **−20**, whose time is charged to `system` anyway
and cannot produce a `nice` count at all.

Arithmetic on that sample checks out, which the earlier one did not:
`1959 + 1421 + 57836 + 59 + 24 = 61299` jiffies = 613.0 s against an
uptime of 614.6 s, and `idle + iowait = 578.95 s` against `/proc/uptime`'s
578.36 s.

**Method note.** The earlier sample looked alarming partly because it was
incoherent: `/proc/uptime` and `/proc/stat` were read in *different shell
commands minutes apart*, so the totals could not be reconciled and the
jiffie counts belonged to a moment ~40 s later than assumed. Two files
that are meant to be compared must be read in one command. Same failure
mode as notes/21 §1 — a number is only as good as the clock you attached
to it.

---

## 6. Where the remaining work is

`systemd-analyze blame`, top of the list:

```
9.739s dev-mmcblk0p2.device
5.225s systemd-resolved.service
5.039s systemd-timesyncd.service
4.306s systemd-networkd.service
3.657s systemd-udev-trigger.service
2.188s systemd-modules-load.service
```

Read with the caveat established in notes/20 and re-earned in notes/21:
**`blame` is wall time inside the unit, not CPU work, and not the critical
path.** Specifically:

- `dev-mmcblk0p2.device` at the top is not work at all. It is when udev
  got round to the rootfs device. Nothing was computing for 9.7 s.
- `systemd-resolved` and `systemd-timesyncd` are 10.3 s of blame between
  them and both are on the "do we need this at all?" list — but part of
  that may be waiting, not computing.

The only trustworthy test remains remove-one-and-measure.

---

## The lesson, stated once

Session 16 asked the right question — *is this boot waiting, or working?* —
and got the right answer for the window it looked at. It then failed to ask
the follow-up: **working towards what?**

Optimising `systemd-analyze`'s number is optimising "when does the machine
stop being busy". Nobody wants that. What they want is "when does the
machine start being useful", and on this board those are nine seconds
apart, in a stretch of time the tool does not report at all.

> Pick the metric that fails if the product fails. Then check whether the
> tool you have been reading measures it.

---

## Next

- Debug-trace the DHCP window and tell hypothesis 1 from hypothesis 2.
- Lever 1, one at a time, measured separately: `systemd-resolved`,
  `systemd-timesyncd`, the `rauc` DISTRO_FEATURE, poky's desktop
  `DISTRO_FEATURES`, journald `Audit=no`.
- Add a **time-to-goal** measurement to the routine so we stop grading
  ourselves on the wrong clock. Time from power-on to "wlan0 has an
  address" is the honest number for this device.
