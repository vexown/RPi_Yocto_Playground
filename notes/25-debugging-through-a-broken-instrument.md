# 25 — Debugging through a broken instrument

An evening that produced three confident wrong diagnoses, all mine, and one
real finding that only became visible after the *logging* was fixed. The
board was healthy the entire time.

## The symptom

The board would work, then stop being reachable. `ssh` gave `No route to
host`; `find-board.sh` sometimes saw its MAC and sometimes did not; the
router's client list kept showing it at .34 throughout. Power-cycling
sometimes brought it back and sometimes did not.

## Wrong diagnosis 1: wifi power save

`brcmfmac: brcmf_cfg80211_set_power_mgmt: power save enabled` is in every
boot's dmesg, and on this chip power save can leave a station associated
while inbound packets go unanswered — which matches "router lists it, nothing
can reach it" well. Dropped when the board turned out to be missing from the
LAN entirely rather than merely quiet. Incidentally, neither `iw` nor
`iwconfig` is in the image, so had it been the answer, fixing it would have
needed a rebuild.

## Wrong diagnosis 2: the power supply

The journal ended at ~18.7 s on three consecutive boots, with no oops, no
panic, no I/O error — a clean cessation, which is what losing power looks
like. The deaths appeared to land in the second right after `Gained carrier`,
when the radio starts transmitting and a Zero W peaks around 350-400 mA.

Falsified directly: the user ran it from a 67 W mains charger and it behaved
identically. The Anker powerbank was never the problem.

## Wrong diagnosis 3: a dying SD card

This one I argued hard, and it was the most seductive because it explained
everything at once:

  - the journal stops without recording an error
  - the board stays alive (the ACT LED on a Zero is active-low: solid at idle,
    flicking off during card access, so "solid with occasional blinks" is a
    healthy idle board — that reading was right)
  - ARP sometimes answers, `ssh` never does. ARP is the kernel replying from
    RAM; `ssh` needs dropbear to fork and exec from disk
  - `sdc` enumerated as **0 bytes** in the reader and needed a re-seat
  - 5 of 17 journal files were corrupt

And the keystone: **no I/O errors in the log** — which I turned from
exculpatory into incriminating by pointing out that an I/O error cannot be
written to the device that is failing. That is a real phenomenon. It was also
unfalsifiable, which should have been the warning.

Falsified by flashing a different physical card, freshly provisioned, which
failed in exactly the same way.

## The actual mistake underneath all three

Every one of those diagnoses was built on the same observation — *the journal
stops at ~18.7 s* — and that observation was an artifact of the logging.

`journald.conf` was all defaults, so `SyncIntervalSec=5m`. With
`Storage=persistent` journald writes into page cache and fsyncs on that
interval. Hard-power a board before the first sync and everything since boot
is gone. 18.7 s is simply where the boot-time burst of logging goes quiet, so
*every* boot cut short reads as "died at 18.7 s".

The fix was one drop-in, applied to the card in the reader:

    [Journal]
    SyncIntervalSec=0

fsync after every message. It costs SD wear and write latency, and neither
matters while chasing something invisible.

**The generalisable lesson:** the instrument shared a failure domain with the
fault. We were diagnosing a board that stops working by reading a log that
stops being written when the board stops working. Nothing recovered from that
channel could distinguish "the board died" from "the log stopped". Four hours
of inference over an unfalsifiable observation.

The image already has a channel that does *not* share that domain —
`console=serial0,115200` is in `cmdline.txt` and `serial-getty@ttyS0` is
enabled. Ten minutes with a UART adapter would have shown all of this live.
That is the tool to reach for first next time, not last.

## What the complete journal showed

With per-message sync, the first captured failure was unambiguous:

    [  18.164] wlan0: Gained carrier
    [ 336.912] wlan0: DHCPv4 address 192.168.50.34/24 acquired

Carrier at 18 s. **No address for another 5 m 18 s.** No address means no
ARP reply, no ssh, nothing findable — the board was not dead, it was waiting.

Two boots, seven minutes apart in wall time, measured the same interval from
their own carrier: 316.7 s and 318.6 s. Deterministic from the board's clock,
not from anything external. And ~318 s is RFC 2131's retransmission ladder
summed out:

    2 + 4 + 8 + 16 + 32 + 64 + 64 + 64 + 64 = 318

Nine failed DHCP attempts, then one that worked. So the client gave up and
retried its way to success; the server did not recover on a schedule of its
own.

That timing also disposes of the router reboot. The user had rebooted the
router immediately before this, which I then recommended as the fix — but two
boots seven minutes apart cannot both take 318 s from their own carrier if an
external event were the trigger.

## What is still unexplained

**The root cause is not found.** What is known:

  - the DHCP server on the router intermittently ignores this board for
    ~5 minutes, then answers
  - it is intermittent, not permanent: earlier the same day, on the same
    router, DHCP completed in ~8 s, and after the fix it completed at 26.3 s
  - one boot also showed the AP actively kicking the board off —
    `CTRL-EVENT-DISCONNECTED reason=3`, then `reason=8`, then several
    `CTRL-EVENT-ASSOC-REJECT status_code=16` over ~40 s before it was let
    back in. No `locally_generated=1` flag, so those came from the AP, not
    from wpa_supplicant
  - signal is not the explanation: `signal_poll` reports RSSI -51 dBm

Candidates not yet tested: ASUS "Roaming Assistant" (RSSI-based disconnects),
airtime fairness, a confused lease table after this board spent a day
alternating between claiming .34 statically and requesting it by DHCP.

Also worth recording: **power-cycling made the symptom worse.** Every reset
performed out of frustration restarted the 318-second timer we were waiting
on. The debugging technique was feeding the fault.

## The fix, and why it is the right shape

`provision-card.sh` wrote `DHCP=no` when given a static address. The hybrid —
static address *and* DHCP together — existed only as a comment in
`network.env.example` telling you to hand-edit the drop-in on the card. It is
now what the script writes by default, with `STATIC_DHCP_FALLBACK=no` for the
old form.

    [Network]
    Address=192.168.50.34/24
    DHCP=ipv4

    [Route]
    Gateway=192.168.50.1
    Metric=2048

Claiming an address is a netlink call to the local kernel: no packet, no
timer, nothing to lose. So the board is reachable the moment it has carrier,
whatever the DHCP server is doing. DHCP still runs alongside, so on any other
network the static address is inert and DHCP is what provides one.

`Metric=2048` is load-bearing and backwards from intuition. networkd gives
DHCP-learned default routes metric 1024 and **lower wins**. At its default
metric the static route would be preferred everywhere — including on a
network where this gateway does not exist, where it would be installed,
preferred, and then blackhole everything. Verified live on the board:

    default via 192.168.50.1  metric 1024    <- DHCP, winning
    default via 192.168.50.1  metric 2048    <- static, the fallback

### The argument for it changed, and got better

The original case for a static address was speed: notes/23 measured the first
DHCP exchange failing on 5 boots out of 5, costing RFC 2131's 4 ± 1 s backoff.
Four seconds. That framing is why the pure-static form won — and why the
hybrid, which is equally fast, was left as a comment.

Four seconds is not the reason. **Being reachable when the network refuses to
cooperate is the reason**, and it is worth two orders of magnitude more than
the saving that motivated the feature. A configuration that is merely fast
when things go well is worth much less than one that works when they do not.

## The measurement

    time to reachable   336 s  ->  17 s   (watcher: down 20:21:11, up 20:21:28)
    clock synchronised   27.5 s -> 19.3 s

The clock improvement is a side effect: timesyncd was waiting on DHCP for its
network, and a static address makes the stack usable 8 seconds earlier. A
change made for reliability paid out in the metric we spent two sessions
optimising, which is the opposite of the usual trade.

## Also recovered tonight

`legacy/deployed-rpios/` — the original `serial_logger.py` and its
hand-written unit, pulled off the Raspberry Pi OS card minutes before it was
reflashed. `notes/19` dissects those files in detail and the repo had never
contained them. Two details the notes never recorded: captures went to
`/home/blankmcu/logs` rather than `/var/log`, and the unit ran as
`User=blankmcu` rather than root.

## Still open

  - **Root cause of the DHCP stall.** Routed around, not fixed. Worth one
    session with the router's logs and Roaming Assistant turned off.
  - **The serial console has still never been used**, and it is the tool that
    would have ended this evening at 18:00. Wire the Debugprobe to
    GPIO14/15/GND before the next hard-to-see fault, not after.
  - `SyncIntervalSec=0` is still on the card as `journald.conf.d/sync.conf`.
    It is a debug measure with a real SD-wear cost. Decide whether to remove
    it or keep it deliberately — an appliance that gets its power yanked has
    a genuine argument for keeping it.
  - The boot-time log filename window (notes/24 §10) is untouched.
