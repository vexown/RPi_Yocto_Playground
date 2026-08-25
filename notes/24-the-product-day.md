# 24 — The product day: roaming, logging, and time

Boot optimisation went on the shelf for this one. The device is needed at
work tomorrow, on a phone hotspot, actually saving logs — so the session's
question was not "how fast" but "does the thing work somewhere I have never
been". Two goals, and neither needed a rebuild: everything that had to change
was provisioning-time.

## 1. The same argument as session 18, landing on the opposite answer

Session 18 decided that an IP address is a fact about the SITE and belongs in
provisioning rather than in the image. That reasoning is unchanged and it is
what made today easy — but applied to a board that MOVES, it inverts:

    one known LAN     a static address is correct, and 4 s faster
    an unknown site   a static address is the one configuration guaranteed
                      to be wrong, because the subnet belongs to somebody
                      else and is not knowable in advance

So the fast path had to be given up for the day. `STATIC_ADDR=none` is new,
and it exists because there was previously no way to say "DHCP" out loud:
`network.env` is sourced by the script, so an empty `STATIC_ADDR=` in the
environment could not override a remembered one — the empty string and "not
set" are indistinguishable to `${x:-y}`.

## 2. Three things must be right on a network you have never seen

The address is only the first, and DHCP handles it. The other two do not
solve themselves, and both had been quietly riding on the home LAN:

**The resolver.** This image is built without systemd-resolved (session 18).
Nothing publishes a DHCP-learned resolver to a file — networkd learns it and
hands it to resolved, and there is no resolved to hand it to. Provisioning
had been writing `/etc/resolv.conf` from `STATIC_DNS`, which defaulted to the
gateway: correct on exactly one network. It is now written unconditionally
from `RESOLVERS`, defaulting to public addresses.

**The clock.** The board has no RTC. `systemd-timesyncd`'s compiled-in
fallback is `time1-4.google.com` — confirmed with `strings(1)` against the
binary in the rootfs, not from memory — so out of the box the clock depends
on DNS, which depends on the resolver above. Provisioning now writes
`/etc/systemd/timesyncd.conf.d/10-ntp.conf` naming servers **by IP address**,
which takes the resolver out of the path entirely. The defaults are the
addresses those four names actually resolve to, plus Cloudflare's.

That mattered more than expected. A logger with a wrong clock produces
evidence you cannot correlate with anything.

## 3. What the NTP measurement showed

    [ 12.933] Starting Network Time Synchronization...
    [ 15.372] restored from recorded timestamp: Tue 2026-08-25 16:18:38 UTC
    [ 15.534] No network connectivity, watching for changes.
    [ 26.464] Network configuration changed, trying to establish connection.
    [ 27.538] Contacted time server 162.159.200.123:123
    [ 27.542] Initial clock synchronization to 2026-08-25 16:20:57.348229 UTC

The clock becomes trustworthy at **27.5 s**, against a boot that finishes at
17.7 s. Almost none of that is NTP: the round trip was 1.06 s here and
**32 ms** on an earlier boot against Google's address. Everything before it is
waiting for DHCP — and the ~8 s from carrier to lease is the same RFC 2131
first-exchange failure measured 5-for-5 in session 18, showing up again now
that the static address is gone. Two independent sessions, same number.

## 4. Discovery belongs on the laptop, not in the image

If the address cannot be predicted it has to be discovered, and the tempting
answer is to make the board announce itself: avahi, mDNS, `ssh rpi0.local`.
That means a new daemon, a dbus dependency, a rebuild and a new failure mode,
installed the night before it matters.

The laptop is already on the same hotspot and therefore already knows the
subnet. `scripts/find-board.sh` sweeps it and matches the board by MAC — the
one property that does not change when it moves. The MACs come from the
host's ARP cache rather than from nmap, because any packet to a local host
populates that cache as a side effect, so no privilege is needed.

Proven live on the hotspot: the phone handed out **10.199.167.62/24**, a
subnet nothing in this repo has ever seen and one I would have guessed wrong
(I would have said 192.168.43.x). Sweeping beats predicting.

The first run also found the Pi 5, because the OUI fallback matches every
Raspberry Pi on the network. `BOARD_MAC` in `network.env` fixes that, and the
fact that the fallback was ambiguous on the first try is the argument for
recording it.

## 5. The PSK was plaintext

Checking the secrets file to add the hotspot answered a question left open in
session 18: the home key was stored as `psk="plaintext"`. Two consequences —
the SD card carries a password that is probably reused elsewhere, and the
Zero W runs PBKDF2, 4096 rounds of HMAC-SHA1, at every boot on a 1 GHz ARM11.

`scripts/add-wifi-network.sh` fixes it, and exists mainly because the obvious
fix does not work. `wpa_passphrase` emits the plaintext back as a comment:

    network={
        ssid="..."
        #psk="the password you just typed"
        psk=<64 hex digits>
    }

Append its output verbatim — the natural thing to do — and the passphrase is
on the card anyway, in a file you now believe is clean. Every comment is
stripped. The passphrase is read with echo off and never reaches argv or
shell history.

To be exact about what the hex form buys: it is password-equivalent, not
encrypted. Anyone holding it can join the network. What it buys is that the
memorable password never sits on a card in a drawer, and that the PBKDF2 goes
away.

## 6. The logger's first run on real hardware

Never exercised before today. The whole chain fired on the first attempt:

    Indeed it is in host mode hprt0 = 00021501
    usb 1-1: New USB device found, idVendor=2e8a, idProduct=000c
    usb 1-1: Product: Debugprobe on Pico (CMSIS-DAP)
    cdc_acm 1-1:1.1: ttyACM0: USB ACM device

    serial-logger@ttyACM0.service - USB serial logger on /dev/ttyACM0
         Active: active (running)

dwc_otg came up in host mode, the probe enumerated, `cdc_acm` bound
`ttyACM0`, the udev rule's `SUBSYSTEM=="tty", SUBSYSTEMS=="usb"` matched,
`SYSTEMD_WANTS` instantiated the template, and bytes landed in
`/var/log/serial-logger/`.

Worth noting *which* device proved it: a CMSIS-DAP Debugprobe presenting a
CDC-ACM port. The deployed Python script only knew about `/dev/ttyUSB*` and
could not see this device at all. Matching by USB ancestry rather than by
node name is the reason the replacement works.

## 7. The logger does not care about the network — demonstrated

Claimed from the unit file, then shown. Across a complete network change
(home LAN -> phone hotspot, different subnet, different AP) the open log file
went from 797 to 5872 bytes with no gap. The unit's only dependency is
`BindsTo=dev-%i.device`; there is no `network.target` anywhere in it, which
is the specific defect it was written to fix.

The corollary is the one that matters in the field: **if the hotspot drops at
work, collection continues — only the ability to read it live is lost.** For
a logger that is the right failure direction.

One correction on the record. I predicted `/proc/<pid>/fd` would show no
sockets. It shows two: fds 1 and 2, the same inode, which are the journald
stdout/stderr sockets systemd hands every service. `AF_UNIX`, not network.
The substance held — fd 3 is the tty, fd 4 is the log file — but the
prediction was wrong as stated.

## 8. wpa_supplicant does not roam

Two networks are now configured, home at priority 10 and the hotspot at 5.
After testing on the hotspot and power-cycling, the board did not come back
to the home LAN — and the router's client list still showed it at .34, which
looked like a contradiction until the laptop's ARP table settled it:

    192.168.50.34 dev wlx98254a83a114 INCOMPLETE

`INCOMPLETE` means the request went out and nothing answered. A router client
list is built from lease and association tables that outlive the association;
ARP from the laptop is the live test. The board was still on the hotspot.

The mechanism is not the priority rule as I first described it. Priority
sorts candidates **within one scan**. It does not preempt an association
already in progress: once wpa_supplicant reaches `COMPLETED` it stays there
until the link drops, no matter what better network becomes visible later.
So if the Zero's single 2.4 GHz radio finishes its first scan while the phone
is audible and the router is not yet, the hotspot wins the whole session.

Practical consequences: at work this runs in our favour, since only the
hotspot exists. At home while tethering, expect the board to sometimes prefer
the phone. `bgscan="simple:30:-70:3600"` in the home block would make it
re-scan while connected and move up, at some power cost. Not needed yet.

## 9. known_hosts is keyed by the name you type

Connecting to the board on the hotspot produced an authenticity prompt even
though the key was already trusted at .34. Not per-network — ssh files a host
key under the string you typed, so a new address is a new binding. That is
the security property, not a bug: without it, any key ever seen could be
presented from any address.

But a prompt you learn to click through is worth less than no check at all,
and a roaming board produces one per site. `find-board.sh` now prints

    ssh -o HostKeyAlias=rpi0-logger -o CheckHostIP=no root@<addr>

which moves the lookup key to a fixed name, so the board keeps one entry
everywhere while a genuinely changed key still fails loudly.

## 10. The timestamp window, and a prediction that failed usefully

USB enumerates early — the logger instance started at **18.8 s** — and the
clock is not trustworthy until **27.5 s**. Anything opened in that 8.7 s
window is named from a restored clock. Tomorrow's normal case (power on with
the probe attached) lands in it every time.

I predicted this would be worse than cosmetic: that `/var/lib` is bind-mounted
onto `/var/volatile`, so timesyncd's clock file could not persist, so every
boot would restore the same image-build timestamp, so every boot-time file
would get an identical name and `O_CREAT | O_APPEND` would concatenate
unrelated sessions into one file.

Wrong. The board restored `Tue 2026-08-25 16:18:38` — the previous shutdown,
not a build epoch. Earlier in the day it restored Aug 22 15:17:26, that
session's last moment. The restore point advances, so names never collide.

Why the reasoning failed, from the unit itself:

    ConditionPathIsReadWrite=!/var/lib

`var-volatile-lib.service` runs **only if /var/lib is not writable**. This
rootfs is read-write, the condition fails, and the unit is skipped — along
with cache, spool and srv. `mount` shows exactly one line, `tmpfs on
/var/volatile`. volatile-binds is not a policy this image applies; it is a
fallback for a read-only rootfs, sitting dormant. So `/var/lib` is on the SD
card, the clock file persists, and its **mtime** is the recorded timestamp
(the file is 0 bytes — there is nothing inside it).

### Three clocks per boot, not two

`systemctl status var-volatile-lib.service` reported its condition check as
having happened at `Thu 2025-05-29 18:48:29 UTC` — a third value again, and
the one that makes the whole picture make sense. Every boot passes through:

    ~0 s     2025-05-29 18:48:29   systemd's compiled-in epoch, baked into
                                   the image and identical on every boot
    ~15.4 s  last shutdown         timesyncd bumps to the clock file's mtime
    ~27.5 s  true time             NTP

So the fixed epoch I predicted does exist — it is just superseded at 15.4 s,
before the logger's 18.8 s start. That is why the collision never happens
here, and it is worth noting the margin is only **3.3 s**. A boot where USB
enumerated faster, or timesyncd started slower, would open a file named
`session_ttyACM0_2025-05-29_18-48-xx.log`, and the next such boot would append
to it.

Today's probe was attached at power-on, so 18.7 s is the real measured
enumeration time for this hardware and not a lucky sample. But the margin is
thin enough to be worth a second measurement before trusting it.

What is actually left is small: the boot-time filename is early by exactly
the time the board spent powered off. Measured here at 2 m 07 s against a
2 m 07 s power-off. Overnight it would be off by the night.

### The part that matters later

This is a live constraint on the still-open **read-only rootfs** item. The
moment `/` goes read-only, all four binds activate, `/var/lib` becomes
RAM-backed, and the failure predicted above stops being wrong: same restored
timestamp every boot, colliding filenames, appended sessions. The fix belongs
with that change, not before it. Candidates:

  - `StateDirectory=` or a tmpfiles rule keeping the clock file on persistent
    storage
  - naming the log file with something clock-independent (boot id) and
    renaming once `/run/systemd/timesync/synchronized` appears
  - `O_EXCL` with a uniquifying suffix, which kills collisions without
    delaying capture by a millisecond

Not doing any of them tonight: they cost a rebuild and a reflash, and the
defect they fix does not exist while the rootfs is writable.

## 11. Tomorrow's runbook

    1. phone hotspot ON first (2.4 GHz, WPA2-Personal), then power the Pi
    2. laptop joins the same hotspot
    3. ./scripts/find-board.sh
    4. ssh with the -o HostKeyAlias=rpi0-logger line it prints
    5. logs are in /var/log/serial-logger/, one file per logger session

The Zero W has one 2.4 GHz radio and no WPA3 worth betting on — wpa_supplicant
here does have SAE compiled in, but brcmfmac on this chip is not something to
discover on a work morning. If the board associates but cannot be reached,
suspect client isolation on the hotspot; the phone's connected-devices list
distinguishes that from a board that never joined.

## 12. Still open

  - The boot-time filename window, tied to the read-only rootfs work above.
  - `dmesg` still reports `FAT-fs (mmcblk0p1): Volume was not properly
    unmounted` after every hard power cycle, and today added several. The
    boot partition is the most corruptible thing on the card and is still
    mounted read-write. Same decision as the read-only rootfs.
  - Boot optimisation, paused: the wpa_supplicant association path, and
    DISTRO_FEATURES still carrying poky's desktop-ish `x11`.
  - `DISTRO_CODENAME` still says `rpi5-era` on a Zero W image, visible in the
    provisioning script's own output.
  - **The board accepts a blank root password.** Surfaced when working out
    what a second laptop would need in order to connect: the answer is
    nothing at all.

        root::15069:0:99999:7:::                 # empty password field
        EXTRA_IMAGE_FEATURES ?= "debug-tweaks ..."
        DROPBEAR_EXTRA_ARGS=" -B"                # -B  Allow blank password logins

    Convenient — no key needs copying onto a work machine, which is the
    right outcome, since a personal private key does not belong on a managed
    laptop. But it means anything else on the same network can log in as
    root. On a personal hotspot with one laptop attached that is nobody; on
    a site LAN it is everybody. Dropping `debug-tweaks` and relying on the
    provisioned `authorized_keys` is the change, and it wants doing at the
    same time as the read-only rootfs — both are "stop shipping a
    development image" work rather than features.
