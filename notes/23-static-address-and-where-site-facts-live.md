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

## Next

**Confirm determinism.** Two or three more reboots, checking that `Gained
carrier` and the printed total stay put. The old behaviour was quantised
and swung by seconds; not swinging is the property we actually bought, and
one boot does not demonstrate it. *(Not yet done.)*

**Then the next block of wait, and it is a big one.** `wlan0: Link UP` at
17.953, but wpa_supplicant does not attempt association until 21.079 — and
once it commits, association plus the full 4-way handshake takes **167 ms**.
So roughly **3.1 s goes to scanning** before it picks an AP. That is now the
largest single block on the path to the goal, and no lever has touched it.
Candidates worth reading up on: a `bssid=`/`freq_list=`/`scan_freq=` pin in
`wpa_supplicant-wlan0.conf` (which would make it a *provisioning* value,
same argument as this session), and whether the driver is doing a full
passive sweep of all channels.

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
- `systemd-analyze`: **21.44 s**, unchanged and expected to stay so.
  Time-to-goal: **~21.25 s**, inferred not measured.
