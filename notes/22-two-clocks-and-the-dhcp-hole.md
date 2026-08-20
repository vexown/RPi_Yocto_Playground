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

### The answer: neither. It is one lost packet.

`SYSTEMD_LOG_LEVEL=debug` on `systemd-networkd` (drop-in, one boot):

```
21.166  wlan0: Gained carrier
21.189  DHCPv4 client: DISCOVER          <- 23 ms after carrier
21.201  State changed: initialization -> selecting
        ............... 3.67 s of silence ...............
24.857  DHCPv4 client: DISCOVER          <- retransmission
24.864  DHCPv4 client: OFFER             <-  7 ms later
24.869  DHCPv4 client: REQUEST
24.872  DHCPv4 client: ACK               <-  3 ms later
24.884  wlan0: DHCPv4 address 192.168.50.34/24 acquired
```

**The first DISCOVER gets no reply. The router answers the second in seven
milliseconds.** The complete DHCP exchange, once it happens, costs 27 ms.

So the gap was never DHCP being slow. It is one dropped frame plus RFC 2131
retransmission backoff. And a frame dropped 23 ms after `Gained carrier` is
a race: networkd fires DISCOVER the moment the carrier flag flips, which is
about when the WPA 4-way handshake completes and before the AP has
necessarily finished putting the station into its forwarding path.

Both hypotheses above were wrong, and one of them was expensive:

- **The DUID theory is dead.** `ClientIdentifier=mac` was proposed on the
  grounds that the AP sees an unfamiliar client after every reflash. The AP
  answered in 7 ms; it has no hesitation about this client whatsoever. The
  change is still worth making for lease *stability* across reflashes, but
  it buys **zero** seconds — and had we shipped it blind alongside anything
  else, the next lucky boot would have been credited to it.
- **"The router is slow" / "networkd sits on its hands."** Neither. Both
  parties were prompt. The medium ate the packet.

### Why the printed number stays steady while the goal metric swings

This looks contradictory and is not. The DHCP wait happens **entirely
outside the window `systemd-analyze` measures**:

```
20.585  Reached target Multi-User System     <- systemd stops the clock here
24.884  wlan0: DHCPv4 address acquired       <- 4.3 s later (9.9 s on the other boot)
```

Nothing in the boot transaction waits for an address. `network-online.target`
is not pulled in by anything on this image, and `multi-user.target` is
satisfied by units having *started*, not by the network *working*. The DHCP
variance is therefore invisible to the total by construction.

**The steadiness of the printed number is not evidence that the boot is
steady. It is evidence that the unsteady part is outside what is printed.**
Which is the same reason the module reorder scored zero: we kept measuring a
window that excludes the thing we care about.

### The goal metric is far noisier than the printed one

| boot | carrier -> address |
|---|---|
| first | 21.22 -> 30.51 = **9.29 s** |
| second | 21.17 -> 24.88 = **3.72 s** |

A 5.6 s swing between two boots of the same image; the slow one almost
certainly lost two DISCOVERs rather than one.

This matters for every measurement from here on. `systemd-analyze`'s number
has a **±0.12 s** noise floor. Time-to-goal has a noise floor of **several
seconds**, and it is *quantised by the retransmission schedule* rather than
continuous — it does not vary smoothly, it jumps between roughly 3.7 s,
9.3 s and so on. Comparing two single samples of it would be meaningless.
N of about 5 is the minimum, and the right summary statistic is probably
"how often did the first DISCOVER survive", not the mean.

> A slow number and a bimodal number need different experiment designs.
> The noise floor is not a property of the board; it is a property of the
> metric.

### Five for five: it is not a race

Five debug boots, all of them:

| boot | DISCOVER #1 | DISCOVER #2 | gap | address | #2 -> address |
|---|---|---|---|---|---|
| A | 21.189 | 24.857 | 3.668 | 24.884 | 27 ms |
| B | 21.358 | 25.557 | 4.199 | 25.585 | 28 ms |
| C | 21.543 | 26.137 | 4.594 | 26.165 | 28 ms |
| D | 21.226 | 24.256 | 3.030 | 24.278 | 22 ms |
| E | 21.237 | 25.865 | 4.628 | 25.895 | 30 ms |

**The first DISCOVER is never answered. Not once in five.**

Two clean signatures fall out:

- **Gap = 4.02 s mean, range 3.030–4.628.** That is 4 s ± 1 s of uniform
  jitter: textbook RFC 2131 retransmission randomization. The variance in
  time-to-goal is not the network being flaky, it is a *deliberately
  randomized retry timer*. Which is exactly why the metric is quantised
  rather than continuous.
- **Second exchange = 22–30 ms, every time.** DISCOVER, OFFER, REQUEST, ACK
  in under 30 ms. The server is fast and boringly consistent.

The 9.29 s boot in the table above was therefore two consecutive losses,
not one slow reply.

**This retires the word "race", which is mine and was wrong.** A race
sometimes wins. Five out of five is structural: the first attempt is doomed
by construction on every boot. Whatever the mechanism is, it is not a
timing coin-flip.

### What is still not known, stated precisely

**We cannot tell from the client side whether the DISCOVER was lost or the
OFFER was.** A request with no reply produces an identical log signature
either way. Separating them needs a capture at the AP or on another host on
the LAN. Everywhere above that says "the DISCOVER is lost" is overreach;
what is actually known is **"the first exchange fails."**

This also means the regdom-change suspect below is *not* exonerated — it
happens on every boot too, so it fits determinism as well as anything else
does. So does "keys not yet fully plumbed into the firmware". The five boots
cannot separate them, and the image has no tooling to try: 113 packages, no
`iw`, no `iproute2`, no `tcpdump`. Probing power-save or link state costs a
rebuild.

### Candidate, not yet a conclusion

From the first boot's log, in exactly the window where the DISCOVER dies:

```
21.234  wlan0: CTRL-EVENT-REGDOM-CHANGE init=COUNTRY_IE type=COUNTRY alpha2=DE
```

The regulatory domain flips from PL (ours) to DE (the AP's country IE)
milliseconds after association, and a regdom change can trigger a channel
list revalidation. That is a plausible mechanism and nothing more. notes/21
section 3 exists because a story about mechanism was told confidently once
already and was wrong within ten minutes; this one gets checked against the
interleaved wpa_supplicant timeline before it goes anywhere near a fix.


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

**Test a static address.** Zero-rebuild experiment — edit the running
rootfs, reboot. It deletes the problem rather than explaining it: no
DISCOVER, no retry timer, no ~4 s, and no variance. It also fixes the
"my IP changes after a reflash" annoyance that started this thread. For a
logger that must be reachable at a known address it is the right design
regardless of boot time.

Expected: address configured within milliseconds of carrier at ~21.2 s, so
time-to-goal goes from ~25.4 s to ~21.3 s. About 4 s, deterministic.

Check first whether .34 is inside the router's DHCP pool; if it is, add a
reservation or pick an address above the pool.

On the board, one short command per line (see "State" below for why):

```
rm -rf /etc/systemd/system/systemd-networkd.service.d
systemctl daemon-reload
cd /etc/systemd/network
cp 20-wlan0.network /root/20-wlan0.network.bak
printf '[Match]\nName=wlan0\n\n' > 20-wlan0.network
printf '[Network]\nAddress=192.168.50.34/24\n' >> 20-wlan0.network
printf 'Gateway=192.168.50.1\nDNS=192.168.50.1\n' >> 20-wlan0.network
printf 'LinkLocalAddressing=no\n' >> 20-wlan0.network
cat 20-wlan0.network
```

Measure with:

```
journalctl -b -o short-monotonic | grep -E 'Gained carrier|wlan0: Configuring'
```

If it works, fold it into `rpi0-network_1.0.bb` — and note that
`ClientIdentifier=mac`, proposed in session 16, becomes moot rather than
merely useless.

Then back to lever 1, one change at a time, measured separately:
`systemd-resolved` and `systemd-timesyncd` (10.3 s of blame between them),
the `rauc` DISTRO_FEATURE on a board with no A/B layout, poky's desktop
`DISTRO_FEATURES`, journald `Audit=no`.

Still completely untouched: **the serial logger has never been exercised on
this board.** Plug the Debugprobe into the data micro-USB port and confirm
the udev rule fires, the template unit instantiates, and a file appears
under `/var/log/serial-logger/`.

---

## State things were left in

- Image on the card is the correct `rpi0-logger-image` with all three
  session-16 changes. **21.390 s mean**, noise floor ±0.12 s.
- **The board still has the debug drop-in at
  `/etc/systemd/system/systemd-networkd.service.d/10-debug.conf`.** It was
  never removed. Every boot is currently paying for debug-level networkd
  logging. Remove it first thing.
- Nothing in the repo changed as a result of the DHCP work — the finding is
  documented, no config was altered. `20-wlan0.network` in the recipe is
  still DHCP.
- Two clocks now in play. Quote the right one: `systemd-analyze` total
  **21.39 s ± 0.12 s**, time-to-goal **~25.4 s** with several seconds of
  quantised spread.

---

## Workflow note

Commands pasted into the board's shell must be **one short command per
line** — no `&&` chains, no heredocs. The copy path prepends two spaces
(which breaks heredoc terminators: `  CONF` never matches `CONF`) and the
terminal hard-wraps at ~115 columns, submitting each fragment as its own
line. Both failure modes cost a round trip this session.
