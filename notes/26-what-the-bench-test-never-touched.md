# 26 — What the bench test never touched

The first day this thing was used in anger it failed completely. Two
independent faults, stacked, each one hiding the other's evidence, and
neither of them in a layer that session 24 had proven working.

The proof from session 24 was real. It was also, it turns out, a proof about
the wrong device.

## The two symptoms, as reported

On a phone hotspot at work:

  1. `find-board.sh` "took forever" and was abandoned. The board was
     eventually found using directly-typed `nmap` commands.
  2. Once found and ssh'd into, plugging in the usual work adapter produced
     **no log file at all**. Nothing in `/var/log/serial-logger/`.

Both turned out to be real bugs. Neither turned out to be the bug I first
went looking for.

## Fault 1 — the finder swept every route, not the local wire

`find-board.sh` took every globally-scoped IPv4 the host held and swept the
enclosing network of each. On a personal PC that is one `/24` and it finishes
in two seconds, which is why it had never been a problem here. On a work
laptop the same loop also finds:

    a docker bridge      172.17.0.1/16     65534 hosts   (nothing there)
    a VPN tunnel         10.x.x.x/16       65534 hosts   (ROUTED, not local)

The docker sweep is merely slow. The tunnel is the killer: those addresses
are not on the local wire, so there is no ARP to fail fast against, and every
one of 65534 probes waits out a timeout that never arrives. Minutes to tens
of minutes — and the script printed nothing at all while it ran, so it was
indistinguishable from a hang.

Three fixes, in order of importance:

  1. **Only sweep what is on the local wire.** The board is a WiFi client on
     the same L2 segment as the laptop. A tunnel or a container bridge cannot
     hold it. Interfaces are skipped by name prefix (`tun tap wg tailscale
     ppp ipsec docker br- veth virbr vmnet`) and by the absence of a
     broadcast flag, which catches point-to-point links the name test misses.
  2. **Clamp the prefix.** Anything wider than `/22` collapses to the `/24`
     around our own address, loudly. Verified against `/16`, `/21`, `/24` and
     `/28` inputs.
  3. **Say what is happening.** Each target is announced before its sweep and
     timed after it, so slow looks slow rather than dead.

Plus a shortcut that beats all three: the address that worked is cached in
`$SECRETS_DIR/last-address` and tried first, verified by MAC rather than by
"something answered". Same hotspot as yesterday is the common case, and it
resolves in under a second with no scanning at all.

**Untested on an actual hotspot.** Written and unit-checked on the LAN only;
that test is the first job of session 27.

## Fault 2 — the adapter has no driver, and never did

The work adapter is:

    067b:2303  Prolific Technology, Inc.  PL2303

The card carried exactly four modules under `drivers/usb/serial`:

    ch341.ko.xz   cp210x.ko.xz   ftdi_sio.ko.xz   usbserial.ko.xz

No `pl2303`. Confirmed on the board, where the device enumerates perfectly
and the chain simply stops:

    usb 1-1: New USB device found, idVendor=067b, idProduct=2303
    usb 1-1: Product: USB-Serial Controller D

No driver binds, so no tty is created, so the udev rule has nothing to match
and the logger is never started. Silent at every layer that has diagnostics
in it, because from the kernel's point of view nothing went wrong: it has no
driver for that hardware, and says so to no one.

This was a plain omission. The comment in the image recipe claimed these
drivers "cover essentially every USB-serial adapter you can buy" while
leaving out one of the two most common cheap bridges on the market. Prolific
and WCH split that market between them; we shipped only WCH.

### The wrong guess that came first, and why it was seductive

Before the adapter was identified, this was blamed on a missing `usbserial`.
The argument:

  - `cdc-acm` is a **complete** driver. It binds the interface and registers
    a tty by itself, depending on nothing.
  - Every other driver in the image is a **bridge** driver — half a thing,
    which knows one vendor's chip and delegates all the tty machinery to
    `usbserial.ko`.
  - Therefore the session 24 bench proof, done with a Debugprobe, had
    exercised the one path in this image that does not need `usbserial` at
    all, and proved nothing whatsoever about the other three.

It fit every symptom, it had a precedent in this very recipe (the
`brcmfmac-wcc` note), and it was wrong. One command on the board killed it:

    # modprobe ftdi_sio
    # lsmod
    ftdi_sio               45056  0
    usbserial              36864  1 ftdi_sio

`usbserial` came in by itself. `kernel-module-split` **does** generate
ordinary module dependencies from modinfo — the thing the brcmutil note says
it "should" do. It does.

So the `brcmfmac-wcc` lesson is narrower than it had been remembered as.
What split cannot see is a **runtime `request_module()`**, not a link-time
module dependency. Those are different mechanisms and only one of them is
invisible to static analysis.

The first half of the argument survives intact, though, and is the real
lesson of the day: **the bench test exercised the only driver class in the
image that shares no code with the product's actual device.** A green light
from a Debugprobe was never evidence about a bridge chip.

## Fault 3 — the board resets when the harness is hot-plugged

Plugging the work harness into a running Pi resets it instantly. No oops, no
panic, no journal entry — the log simply stops, which is what losing power
looks like rather than what crashing looks like.

Three hypotheses died in order, each to a cheap experiment:

**"The adapter's own inrush."** Adapter alone, nothing on the far end,
plugged into a running Pi: enumerates fine, no reset. Dead.

**"The powered target draws too much through it."** Harness connected but the
target's own supply switched **off**: still resets. The thing was not even
running. Dead.

**"A Zero W simply cannot source this."** Killed by an observation from
outside the evening's evidence entirely: the previous Raspberry Pi OS
deployment logged this same device, through this same adapter, on this same
board, with no such problem. And the README in `legacy/deployed-rpios`
records that the old Python logger **burned 100% of the core while idle** on
a spin loop — so the old setup had *less* power headroom than ours, not more.
Any explanation of the form "our image leaves less margin" is dead on
arrival. Dead.

### What it actually is, and the observation that settled it

It is the hotplug transient, and nothing else. The proof was already sitting
in the failure and took an outside eye to notice:

> the Pi reboots with the adapter still connected, so it's running with the
> adapter, but only after it reboots itself

The board's own reset cycle **is** the "connect first, then power on"
experiment, and it passes every time. Confirmed directly:

    [    4.308240] usb 1-1: New USB device found, idVendor=067b, idProduct=2303

Enumeration at 4.3 s of a normal boot, board stays up indefinitely
afterwards, and it survives the target device being power-cycled on the other
end of the cable. Steady-state draw is a non-issue. Only the instant of
insertion into a live 5 V rail matters.

Why a PC shrugs it off and a Zero W does not is structural rather than a
matter of margins. On a PC the USB port is a *load on a supply*: a dedicated
5 V rail with large bulk capacitance, a per-port fuse around 1–2 A, and a CPU
that runs from 12 V through its own VRM and never sees the transient. On a
Zero W the OTG port's VBUS is essentially the board's 5 V net — the same node
that feeds the regulator making the SoC's core voltage. There is no port
power switch, no current limit, no soft-start. A transient there is not drawn
from a supply that serves the port; it is drawn from the supply that *is* the
CPU.

**Closed with a procedure, not a fix:** connect the harness before applying
power. This is how a deployed appliance is used anyway, and it is almost
certainly why the Pi OS deployment never met this — it was never hot-plugged.
Accepted deliberately; a powered hub or a bulk capacitor remains available if
hotplug is ever needed.

## The filename is lying, and now it matters

The first successful capture landed as:

    session_ttyUSB0_2025-05-29_18-48-36.log

That is systemd's compiled-in epoch — `2025-05-29 18:48:29` — plus seven
seconds. Predicted in notes/24 §10; no longer theoretical.

The board has no RTC. The logger starts when udev sees the device, which is
around 18.8 s, and NTP does not land until later. So **every device attached
at boot gets a session file stamped May 2025**, and a week of captures is a
directory of identically-misdated files with no way to tell which shift is
which. The `/var/lib/systemd/timesync/clock` restore that notes/24 documented
does not help on a freshly flashed card — there is no saved timestamp yet,
and a board that keeps getting hard-reset never writes one cleanly.

The obvious fix is the wrong one. Ordering the unit after `time-sync.target`
puts the network back in front of a USB reader, which is the single worst
line removed from the old unit and the whole reason `BindsTo=dev-%i.device`
exists.

## What is fixed, worked around, and open

**Fixed and verified on hardware:** `pl2303` ships in the image. The adapter
binds, `/dev/ttyUSB0` appears, the udev rule matches, the template
instantiates, and a full boot of the target device was captured end to end,
including surviving the target being power-cycled mid-capture.

**Worked around, closed:** hotplug reset. Connect before power.

**Written, untested:** `find-board.sh`. Needs a real hotspot.

**Open, and now designed:** see below.

## For session 27

### 1. Fix the timestamp with `TFD_TIMER_CANCEL_ON_SET`

A `timerfd` on `CLOCK_REALTIME` created with this flag becomes readable with
`ECANCELED` when something **steps** the wall clock — which is exactly what
timesyncd does at NTP sync. It is the mechanism Linux provides for this
problem specifically.

The logger adds that fd to the `poll()` loop it already has, and on
cancellation computes what its real start time *was*
(`realtime_now − monotonic_elapsed`, both of which it knows) and renames its
own file.

Why this shape: it adds **no ordering dependency at all**. The unit still
starts the microsecond udev sees the device, still has no `network.target`
anywhere near it, and the correction arrives ~8 s later on its own. Roughly
twenty lines in a program already built around `poll()`. The fallback, if it
turns awkward, is honest sequence numbers — `session_ttyUSB0_0001.log` — at
the cost of not knowing when anything happened.

### 2. Rotate on `SIGHUP`

Because the adapter cannot be unplugged without resetting the board, every
capture accumulates into one file forever. The operator wants "start a new
file *here*", and the Unix idiom for that is `SIGHUP` — precisely what
logrotate uses. Close the current file, open a fresh one with a new
timestamp:

    systemctl kill -s HUP serial-logger@ttyUSB0

Small change to a program that already has a signal handler, and it composes
with item 1: a file opened after the clock is good gets a correct name
immediately.

### 3. A logging tool worth shipping

An OS built specifically to log serial devices currently ships no way to
*operate* the logging. Everything is `tail -f`, `tee` and remembering which
gotcha bites — `tail -f` replays the last 10 lines unless given `-n 0`, `tee`
truncates unless given `-a`, and `grep` block-buffers into a pipe unless
given `--line-buffered`.

A small ASCII-menu script on the target, wrapping the operations that
actually come up: start a new file (item 2), rename the current one, list
captures with real sizes and times, follow live, follow filtered, slice a
byte range out of an existing capture, show which instances are running.

That last one matters more than it sounds: `wc -c` before and after an
interesting window, then `tail -c +N | head -c M`, is exact and leaves no
process running — much better than replaying a live stream through `tee` and
hoping to hit Ctrl-C at the right moment.

## Two corrections on the record

**On the SD card from session 25.** That evening argued hard that the card
was dying, partly from corrupt journal files and an unclean FAT. Those are
also exactly what a board that keeps losing power produces, and this session
produced plenty of that. The card evidence was weaker than it was treated as
being. (It does not overturn session 25's conclusion — the board went
unreachable with nothing plugged in, and the Pico W corroborated the router —
but the specific card argument should not be reused.)

**On reading silence as evidence.** Midway through this session the absence
of `ftdi_sio` registration lines in `journalctl -b -1 -k` was about to be
called journal truncation — the exact mistake session 25 is named after. The
`sync.conf` drop-in with `SyncIntervalSec=0` was present and working the
whole time. The real explanation was mundane: the board had reset several
times, and `-b -1` was simply not the boot the `modprobe` had run in. Two
sessions running, the instinct to blame the instrument was wrong in a new
way — first by trusting it, then by distrusting it.
