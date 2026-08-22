# 23 — A static address, and where a site fact belongs

Session 18. Short session, one experiment, one design decision.

The experiment closes the hole notes/22 opened. The design decision is the
more interesting half, and it is about a distinction that only becomes
visible once you provision a second kind of thing.

---

## 1. The experiment

Session 17 ended with a board that finished booting at 21.39 s and did not
have an IP address until 24.9–30.5 s. The gap was not the router being
slow: across five instrumented boots the **first DHCP exchange failed every
single time**, and networkd then waited out RFC 2131's retransmission
backoff — 4 ± 1 s of uniform jitter — before a retry that completed in
about 25 ms.

The obvious response to "the first exchange always fails" is to find out
why. The cheaper response is to notice that we do not need the exchange.

So: a static address, edited straight into the running rootfs, no rebuild.

```
[Match]
Name=wlan0

[Network]
Address=192.168.50.34/24
Gateway=192.168.50.1
DNS=192.168.50.1
LinkLocalAddressing=no
```

### The result

```
Startup finished in 4.417s (kernel) + 17.022s (userspace) = 21.439s
multi-user.target reached after 16.290s in userspace.
```

**21.439 s against a baseline mean of 21.390 ± 0.12** — unchanged, and that
was the prediction. This change removes *wait*, not *work*, and the wait
was outside the window `systemd-analyze` measures. Had the printed total
moved, something would have been wrong with the model in notes/22.

The whole networkd log for the boot is now nine lines:

```
[   13.435680] Starting Network Configuration...
[   17.640124] lo: Link UP
[   17.656687] lo: Gained carrier
[   17.756468] Enumeration completed
[   17.762189] Started Network Configuration.
[   17.809388] wlan0: Configuring with /etc/systemd/network/20-wlan0.network.
[   17.953442] wlan0: Link UP
[   21.184413] wlan0: Connected WiFi access point: StatekMatka_V2
[   21.248548] wlan0: Gained carrier
```

No DISCOVER. No retransmit. No 4-second gap. `Gained carrier` at 21.248 is
the last networkd event of the entire boot, and `networkctl` afterwards
says `State: routable (configured)`, `Address: 192.168.50.34`.

| | before (DHCP) | after (static) |
|---|---|---|
| carrier | ~21.14 | 21.248 |
| address | 24.884 – 30.512 | ~21.25 (see caveat) |
| `multi-user.target`, absolute | 20.585 | 20.707 |
| goal past the finish line | 4.3 – 9.9 s | ~0.5 s |

### The caveat, stated rather than glossed

**There is no log line timestamping the address.** Static addressing
produces no default-level output — the lines we were reading before were
DHCP *client* chatter, and there is no equivalent — and even the transition
to `routable` is not logged at the default level.

What is measured: `Gained carrier` at 21.248 is the last networkd event of
the boot, and the link ended up configured. What is inferred: since setting
an address is a netlink call handled in the same event-loop turn as the
carrier notification, the address is up within milliseconds of 21.248.

That last step is reasoning, not measurement. Session 17 contained two
confident predictions about DHCP that were both wrong, so the distinction
is worth keeping. Converting it into a measurement costs one boot with
`SYSTEMD_LOG_LEVEL=debug`; it has not been spent yet.

### Why it is deterministic, not just faster

This is the part worth internalising, and it is not "static is faster".

An IP address is not something a router grants. It is a property a host
assigns to its own interface — an entry in a kernel data structure saying
"wlan0 holds 192.168.50.34, and the /24 means 192.168.50.0–255 are on my
local wire". Setting it consults nothing and asks no one.

Traffic finds you by **ARP**: another host broadcasts "who has
192.168.50.34?" and whoever claimed it answers with its MAC. Address
ownership on a LAN is **asserted, not granted**. The network has no
authority that approves it.

Which makes DHCP a *bookkeeping convention*, not an allocator with teeth. A
server holds a pool, keeps a ledger, and clients politely ask. Nothing
compels a client to participate.

So a static address is not a faster version of the DHCP conversation. It is
the **absence** of a conversation. A network exchange can lose a packet; a
netlink call cannot. That is why the saving is deterministic where DHCP was
handing us a quantised 4-or-9 seconds.

### And why a router-side "static IP" would not have helped

What consumer routers call a static IP — ASUS says "Manually Assigned IP
around the DHCP list" — is a **DHCP reservation**, a genuinely different
mechanism. The client still broadcasts DISCOVER, still waits for OFFER,
still REQUESTs, still waits for ACK. The server just always answers the
same.

Our problem was never *which* address we got. It was the **round trip**. A
reservation keeps the round trip and makes the answer predictable; going
static on the device deletes the round trip.

A reservation is still worth having — see §3 — but as a safety measure, not
a speed one.

---

## 2. Where does the address live?

The board now has a static address. The question is what to do with that
fact: bake it into the recipe, or apply it at provisioning time.

`provision-card.sh` already documents a split, in its own header:

> in the repo — the image, the recipes, this script, and an EXAMPLE of the
> credential file's format
> outside it — the credential files themselves, in `$SECRETS_DIR`

That split is drawn along **secret / not-secret**. It decides the PSK
immediately. It does not decide an IP address at all, because there is
nothing wrong with `192.168.50.34` appearing in a public commit.

The axis that decides it is a different one: **property of the site, or
property of the product?**

Those two axes look like a single axis for as long as the only thing you
provision is a PSK — which is both secret *and* site-specific. The address
is the case that pulls them apart, and it lands: not secret, but very much
site-specific.

An image with one LAN's address compiled into it only works on that LAN.
That is a worse artifact, and it is worse in a specific direction: a card
flashed for the wrong site would boot perfectly and be unreachable, which
for a headless board is the worst available outcome.

**So: provisioning, not the recipe.**

### As a drop-in, not a rewrite

`provision-card.sh` now writes
`/etc/systemd/network/20-wlan0.network.d/10-static.conf`. networkd merges
`<name>.network.d/*.conf` over the base file the same way systemd merges
unit drop-ins.

Four things that buys over overwriting `20-wlan0.network`:

- the recipe's file stays pristine and stays *readable* — it remains the
  documented product default rather than something a script clobbers
- what was provisioned is one small file you can `cat` or `diff`; before
  this, the only record that a board was static was a `.bak` in `/root`
- undoing it is `rm` of one file, not "restore the backup you hopefully
  still have"
- it composes — the hybrid config in §4 is an edit to the drop-in, and the
  base file never moves

### The direction of the default is the design

The image ships `DHCP=ipv4`. The static address is opt-in.

That is backwards from "make the product fast by default", and
deliberately. **The fast path is the one you ask for; the safe path is what
you get when something goes wrong.** An unprovisioned card, or one
provisioned for the wrong site, comes up on DHCP and can be found. Before
this session we had it the other way round — the fast path baked in, the
safe path requiring a card pull.

The value comes from `$SECRETS_DIR/network.env`, with environment override,
mirroring the `PUBKEY` pattern the script already used. `$SECRETS_DIR` is
mildly misnamed once a non-secret lives in it. It is still the right home:
it exists, it is outside the repo, and it survives reflashes. Inventing a
second location for one more site fact is worse than an inaccurate
directory name.

### The one validation worth writing

The script's stated philosophy is that *an error message which lists the
valid answers is worth ten that state the problem*. The failure this
feature can introduce is precisely an unreachable headless board, and the
overwhelmingly common cause is a **gateway outside the address's prefix** —
`192.168.50.34/24` with `Gateway=192.168.1.1`. The kernel accepts it,
installs a default route via a next-hop ARP can never resolve, and the
board boots to silence.

That is integer arithmetic on two dotted quads and a netmask, and it
deletes the whole failure class. It runs *before* the mount, so a bad value
never reaches the card. Alongside it:

| rejected | because |
|---|---|
| `192.168.50.34` (no prefix) | the prefix is how the kernel decides what is on-link |
| `/33`, `/0` | out of range |
| `192.168.50.0/24`, `192.168.50.255/24` | network and broadcast are not host addresses |
| `192.168.050.34` | leading zeros are octal to shell arithmetic and to `ping` |
| `192.168.50.300` | not an octet |
| gateway outside the prefix | the failure class above |
| gateway == the board's own address | typo |
| `STATIC_ADDR` set, `STATIC_GW` unset | must say `STATIC_GW=none` out loud |

The last one is worth defending. A static address with no gateway is a
legitimate configuration for an isolated sensor — LAN reachable, nothing
else. But *forgetting* the line and *choosing* not to have a gateway
produce an identical file and very different intentions, and the script
should not guess which you meant.

Fifteen cases were run against the validator before it went in the repo.

---

## 3. Reserve it on the router anyway

Not for speed — the board is not asking any more.

Because §1 established that a LAN has no authority arbitrating address
claims. A static address the DHCP server does not know about is an address
it will hand to somebody else once the board's old lease ages out. Then two
hosts answer the same ARP query, with no referee. The symptom is
intermittent, asymmetric, and looks exactly like flaky hardware.

Two ways to prevent it:

- **a reservation** for the board's MAC (ASUS: LAN → DHCP Server → Manually
  Assigned IP). Low effort, disturbs nothing else. Recommended.
- **shrink the pool** and keep static devices outside it. Structurally
  cleaner — the server *cannot* hand out the static range — but it touches
  every device on the LAN.

Not done yet on this network. `.34` is currently protected only by the live
lease the board acquired before it went static, which is ASUS's default
86400 s.

One thing that turned out not to be true: I claimed a static device would
drop off the router's client list. It does not — this router builds that
list from ARP and the associated-station table, not from DHCP leases.

---

## 4. The hybrid, recorded but not shipped

If this board ever has to survive an unknown network, networkd will do both
at once:

```
[Network]
Address=192.168.50.34/24
DHCP=ipv4

[Route]
Gateway=192.168.50.1
Metric=2048
```

The static address is configured immediately at carrier, so time-to-goal
stays where §1 put it; DHCP runs alongside in the background and it stops
mattering whether it takes 4 s or fails outright.

`Metric=2048` is the non-obvious part, and it is **backwards from what you
would naturally write**. networkd gives DHCP-learned default routes metric
1024, and lower wins. Leaving the static route at its default metric makes
it preferred *everywhere* — including on a network where 192.168.50.1 does
not exist, where it would be installed, preferred, and then blackhole every
packet leaving the LAN. Pushing it to 2048 makes DHCP win wherever a DHCP
server exists, and leaves the static gateway as the fallback for when none
does.

Documented in `scripts/network.env.example`, not implemented as a branch in
the script. One board, one LAN; the flag can be added the day there are two.

---

## 5. What this changed in the repo

| file | change |
|---|---|
| `scripts/provision-card.sh` | reads `network.env`, validates, writes the drop-in; removes a stale one on re-provision |
| `scripts/network.env.example` | new — the settings, and why each exists |
| `.../rpi0-network/files/20-wlan0.network` | comment rewritten with the measurement, and a correction |
| `.gitignore` | `network.env` ignored, `.example` kept |

The recipe's old comment said a static address "removes the DHCP
round-trip from the boot critical path". **The round-trip was never on the
critical path** — nothing in the boot transaction waits for an address,
which is the entire subject of notes/22. Corrected in place rather than
quietly deleted, same as notes/21 §6.

---

## The lesson, stated once

> Two axes were doing the work of one. Ask *is it secret* and you get the
> PSK right and the address wrong. The second question is *does this
> describe the product or the site* — and the answer decides whether a fact
> belongs in an image you rebuild, or in the operation that puts a card in
> a particular board on a particular LAN.

---

## 6. Determinism: mostly, and the residual moved

Four boots on the static config:

| boot | printed total | `wlan0: Gained carrier` |
|---|---|---|
| first | 21.439 | 21.248 |
| #1 | 21.430 | 21.166 |
| #2 | **21.107** | **22.652** |
| #3 | 21.236 | 21.300 |

Three of the four cluster inside **134 ms**. Boot #2 is 1.4 s late.

The DHCP behaviour is gone: no quantised 4-or-9 second steps, no 30.5 s
tail. Against the old 24.9–30.5 s, time-to-goal is now 21.2–22.7 s, so
**3.7 to 9.3 seconds removed**. That result stands.

But "deterministic" was too strong. About 1.4 s of variance survives, and
it has moved into the association path.

Boot #2 is the one to stare at: **lowest printed total, latest carrier.**
The two clocks moving in opposite directions inside a single boot — notes/22
as a data point rather than an argument.

Also worth not rounding away: the printed totals now spread 0.332 s over
four boots, where the session-17 baseline spread 0.125 s over three. Might
be sample size, might be real. The ±0.12 figure should stop being quoted
until it is re-established.

---

## 7. Correction: it was never "3.1 s of scanning"

This document's first draft said *"roughly 3.1 s goes to scanning before it
picks an AP."* That was a guess dressed as a finding, and the measurement
says otherwise. Boot #3, all timings from the one boot:

| span | Δ | what |
|---|---|---|
| → 18.960 | ~1.0 s | wpa_supplicant **not started yet** |
| 18.960 → 19.557 | 0.597 | daemon init |
| 19.557 → 20.540 | 0.983 | init → regdom change |
| 20.540 → 21.118 | 0.578 | regdom → association attempt |
| 21.118 → 21.280 | 0.162 | associate + full 4-way handshake |

Only the middle ~1.56 s is even a candidate for scanning. A third of the
gap is the daemon not running, and 0.6 s is its startup. Three different
problems wanting three different fixes. (The ~1.0 s is cross-boot — `Link
UP` came from a different boot — so treat it as approximate.)

### Why it starts at 18.96, and a side effect we caused

```
wpa_supplicant@wlan0.service @14.540s
`-basic.target @13.913s
```

`@` times are offsets from the start of userspace; journal monotonic runs
from boot. 14.540 + 4.417 = **18.957**, which is the journal's 18.960.
Same event. Worth pinning down since we now mix the two routinely.

`Requires=sys-subsystem-net-devices-wlan0.device` is satisfied at 14.158,
so the device is not the gate. The unit is `WantedBy=multi-user.target`
with default dependencies, hence ordered after `basic.target` — and that
does not arrive until 18.330 absolute. The supplicant is **blocked, not
queued**, which was worth checking on a core running at 97%.

And this exposes a side effect of our own work. Session 17's
`10-wifi-early.conf` pushed `systemd-modules-load.service` from ~0 s to
2.085 s, and that service is inside `sysinit.target`, which gates
`basic.target`, which gates the supplicant. The lever-4 change partly works
against itself.

Still net-positive — without it `wlan0.device` would not exist until 21.5 s
and `Requires=` would have pinned the supplicant there regardless — but
reordering is not side-effect-free even when it conserves work.

---

## 8. Where the boot actually ends now

```
multi-user.target @16.309s
`-systemd-logind.service @14.384s +1.853s
  `-basic.target @13.913s
    `-sockets.target @13.883s
      `-dropbear.socket @13.853s
        `-sysinit.target @13.663s
          `-systemd-vconsole-setup.service @15.973s +777ms
```

Two things fall out, both lever 1 — deleting work, which on a work-bound
boot comes straight off the total.

**`systemd-logind`, 1.853 s, and it is the last gate on
`multi-user.target`.** A headless appliance whose only login path is
dropbear, which does not use logind.

**`systemd-vconsole-setup`, 777 ms.** Setting up a virtual console font and
keymap on a board with no monitor, no keyboard, and — since session 17
dropped the vc4 overlay — no framebuffer at all. For scale, session 17's
entire shipped gain was 0.616 s.

Caveat on the tree: it is non-monotonic (`systemd-vconsole-setup` @15.973
sits under `sysinit.target` @13.663), a known `critical-chain` artefact —
it follows `After=` edges that need not be causal. So "on the critical
chain" is soft. The `+777ms` itself is solid.

### The blame list, and why it cannot be added up

```
9.508s dev-mmcblk0p2.device      1.864s systemd-journald.service
5.281s systemd-resolved.service  1.853s systemd-logind.service
5.160s systemd-timesyncd.service 1.423s systemd-udevd.service
4.374s systemd-networkd.service  1.415s systemd-journal-flush.service
3.864s systemd-udev-trigger.svc  1.279s systemd-remount-fs.service
2.085s systemd-modules-load.svc  1.278s systemd-userdbd.service
```

…then a long tail of `sys-kernel-debug.mount`, `dev-mqueue.mount`,
`modprobe@fuse`, `modprobe@drm`, `tmp.mount` all sitting between 1.13 s and
1.17 s. Mounting `/tmp` does not take 1.1 s of work. That tight cluster is
the **signature of a saturated core**: they all started together, all
finished together, and each one's "duration" is mostly time spent waiting
for the CPU behind the others.

Which is the reason these figures cannot be summed, and the reason the
method stays what notes/21 established: delete one thing, measure the
total, repeat.

---

## 9. Lever 1, measured one at a time

Both candidates from §8 were tested with `systemctl mask` and reboots —
**zero rebuild**, so the number arrives before any Yocto change is written.
That inverts session 17, where three changes shipped together and had to be
attributed afterwards by signature.

| configuration | boots | mean total | spread |
|---|---|---|---|
| session 17 baseline | 3 | 21.390 | 0.125 |
| + static address | 4 | 21.303 | 0.332 |
| + `systemd-vconsole-setup` masked | 3 | 20.816 | 0.145 |
| + `systemd-logind` masked | 6 | **19.472** | 0.518 |

- **`systemd-vconsole-setup`: −0.487 s.** A console font and keymap for a
  board with no monitor, no keyboard and — since session 17 dropped the vc4
  overlay — no framebuffer.
- **`systemd-logind`: −1.344 s.** The last gate on `multi-user.target`, on a
  board whose only login path is dropbear, which does not use it.

**Cumulative for the session: 21.390 → 19.472, i.e. −1.918 s (9.0%)**, plus
the 4–9 s taken off time-to-goal by the static address. Carrier now lands at
**20.517 s** mean over six boots.

### The blame list as an estimator

Both predictions were made in advance from the blame figure, and both came
in low:

| unit | blame | actual | ratio |
|---|---|---|---|
| `systemd-vconsole-setup` | 0.777 | 0.487 | 63% |
| `systemd-logind` | 1.853 | 1.344 | 73% |

The gap is contention. A blame number is *wall time inside the unit*, and on
a core at 97% part of that is the unit sitting in the run queue behind
others. Deleting the unit deletes its **work**; its share of the queueing
just redistributes.

So the working rule, now with two data points behind it: **treat blame as an
upper bound and expect to keep roughly two thirds.** Useful for ranking
candidates, useless as a promise.

---

## 10. A non-result: the journal pile costs nothing at boot

Recorded so it is not chased again, in the manner of §5.

`/var/log/journal/` had accumulated **30 files, 9.8 MB**, one more per
reboot. With `systemd-journald.service` at 1.864 s of blame and
`systemd-journal-flush.service` at 1.415 s, the pile looked like both a
lever and — worse — a **confound**, since every measurement reboot this
session had been growing it.

`journalctl --vacuum-files=1` freed 8.5 MB, leaving one file. Six boots
after:

```
before vacuum (excluding one outlier):  19.487
after  vacuum (6 boots):                19.472
```

**A difference of 15 ms — nothing.** The pile is neither a lever nor a
confound, and the earlier measurements taken while it grew are fine.

The mechanism, which should have been obvious beforehand: **journald is the
writer, and a writer does not read archived journals.** Only `journalctl`
opens them, and only when you query. Archived files cost query time, not
boot time.

`SystemMaxUse=` and `SystemMaxFiles=` remain worth setting — 9.8 MB of logs
accumulating unbounded on an SD card is a real problem for a device meant to
run unattended — but as a **storage** measure. Not a boot-time one.

### Two side findings from the same detour

**`orphan cleanup on readonly fs` appears on every boot of this image, clean
shutdown or not.** It looked like evidence of unclean shutdown and is not:
systemd remounts `/` read-only at shutdown but never unmounts it, and ext4
only processes the orphan list at unmount. A `systemctl start reboot.target`
— unambiguously clean — produces the same line. This briefly caused the
logind measurement to be written off as contaminated; it was not.

The evidence that settled it: the only two `.journal~` (unfinalised) files
in the directory decoded to **2025-05-29 18:48:28**, the stale pre-timesync
clock of a much older boot. Every file from the measurement session was a
clean `.journal`. So the reboots where `systemctl reboot` printed *"Call to
Reboot failed"* had in fact shut down normally — the error was on the D-Bus
reply path while the shutdown transaction proceeded.

**`journalctl -b -1` does not work on this board.** Not lost data — 20 boots
were retained. Every boot's journal *begins* in May 2025 and *ends* in
August 2026, because the Zero W has no RTC and timesyncd corrects the clock
mid-boot. Relative boot offsets are resolved by realtime ordering, and that
ordering is scrambled. Name the boot ID explicitly instead:
`journalctl -b <boot-id>`. This will be true of every RTC-less board.


---

## Next

**Lever 1, one change at a time, measured separately.** Every candidate
below is testable with `systemctl mask` and a reboot — **zero rebuild** —
so the Yocto change only gets written after the number is known:

1. ~~`systemd-vconsole-setup`~~ — done, −0.487 s (§9)
2. ~~`systemd-logind`~~ — done, −1.344 s (§9)
3. `systemd-resolved` — 5.281 s blame, the largest left. Check what
   `/etc/resolv.conf` is first: if it points into `/run/systemd/resolve/`,
   masking resolved breaks DNS until a static `resolv.conf` replaces it.
4. `systemd-timesyncd` — 5.160 s blame. The logger needs correct time, so
   this is about *when* it runs, not whether. Note the RTC-less clock jump
   in §10 — timestamps before timesync are wrong, which matters for a device
   whose product is timestamped data.
5. `systemd-udev-trigger` — 3.864 s blame, not yet looked at.

**Then convert the masks into image changes.** poky's systemd recipe has
`PACKAGECONFIG` entries for `vconsole` and `logind`, so the product form is
a `systemd_%.bbappend` with `PACKAGECONFIG:remove`, which deletes the
binaries rather than shipping them and refusing to run them. Masking also
showed its edge this session: masking `systemd-logind` left the D-Bus alias
`dbus-org.freedesktop.login1.service` resolving to a masked unit, which
broke `systemctl reboot` with *"File exists"*. Building without logind
removes the alias too, so the conflict cannot arise.

**Then the association path**, which now holds the residual 1.4 s of
variance. Needs `wpa_supplicant -d` for one boot to see scan events; the
default log level shows none. If it is a full 2.4 GHz sweep, `scan_freq=`
in `wpa_supplicant-wlan0.conf` makes it a *provisioning* value under the
same product-vs-site argument as §2 — with the tradeoff that the router
runs auto channel selection, so pinning one channel breaks the day it
moves. Listing 2412/2437/2462 keeps most of the win and most of the
robustness.

**Also unresolved:** whether the PSK is stored plaintext (PBKDF2-SHA1 ×4096
at every boot) or as the derived hex key. The first check used
`grep -c 'psk="'`, which returned 2 — but the real config was copied from
our example, and the example carries a *comment* line containing `psk="`.
Pattern was too loose. `grep -cE '^[[:space:]]*psk="'` is the honest test.

**Still open from before:** lever 1 one change at a time — `systemd-resolved`
and `systemd-timesyncd` (10.3 s of blame between them), the `rauc`
DISTRO_FEATURE on a board with no A/B layout, poky's desktop
`DISTRO_FEATURES`, journald `Audit=no`.

**Still completely untouched: the serial logger has never been exercised on
this board.** Plug the Debugprobe into the data micro-USB port; confirm the
udev rule fires, the template unit instantiates, and a file appears under
`/var/log/serial-logger/`.

---

## State things were left in

- The board is running the **hand-edited** static config, with the original
  at `/root/20-wlan0.bak`. The repo's drop-in mechanism is written but has
  **not been exercised** — that needs a reflash + provision cycle.
- `~/.rpi0-secrets/network.env` **does not exist yet**. Create it from
  `scripts/network.env.example` before the next provision, or the card
  comes up on DHCP.
- The debug drop-in from session 17 was removed at the start of this
  session. The board is clean.
- No reservation on the router yet. `.34` is held only by a lease.
- `systemd-analyze`: **19.47 s** mean over six boots (19.296–19.814), with
  `systemd-vconsole-setup`, `systemd-logind` and
  `dbus-org.freedesktop.login1` masked **at runtime only** — none of it is in
  the image yet, and a reflash loses all three.
- Time-to-goal: carrier at **20.52 s** mean, still inferred rather than
  measured directly (§1 caveat).
- The journal was vacuumed to one file. The board's boot history before
  2026-08-22 12:56 is gone.
