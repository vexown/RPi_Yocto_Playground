# Session 12 — RAUC part 2: install a bundle, then force a rollback

Follows straight on from notes/16, which got the A/B boot chain working but
never shipped an update through it. This session closes Phase 5: build a
signed bundle, install it over the network onto a running Pi, boot the new
slot, then deliberately break it and watch the board demote itself back.

Status: **DONE.** Every step verified on target 2026-08-15.

## Making the update visible first

A bundle built from the same source as the running system is a useless
test: "did it install?" would rest entirely on RAUC's own reporting, which
is the thing under test. So before building anything, `DISTRO_VERSION` went
0.1 -> 0.2 in `playground.conf`.

The card was **not** reflashed, deliberately. Slot A therefore stayed at
0.1 while the bundle carried 0.2, which makes `/etc/os-release` an
independent witness to which slot booted — one that knows nothing about
RAUC. The rollback at the end is visible the same way, in reverse.

Two markers, deliberately different, so they can't be confused:

| marker | source | value |
|---|---|---|
| `VERSION_ID` in `/etc/os-release` | the installed **rootfs** | `0.2` |
| `version=` in `rauc status --detailed` | the bundle's **manifest** | `0.2-ota-demo` |

Side effect worth knowing: `DISTRO_VERSION` also feeds `SDKPATH`, so the
next `populate_sdk` installs to `/opt/playground/0.2`, not the
`/opt/playground/0.1` that notes/15 documents.

## The bundle

`bitbake playground-bundle` -> a 60 MB `.raucb` from a 377 MB rootfs.
`rauc info` on the host, before going anywhere near the Pi:

```
Compatible:    'playground-raspberrypi5'
Version:       '0.2-ota-demo'
Bundle Format: verity
Manifest Hash: 'd7c186cc...9e3a45'
1 Image: [rootfs] checksum 021dbc21...537d511, 377,487,360 bytes
Verified inline signature by 'O = Playground, CN = Playground Development Signing Key 1'
```

Curiosity confirmed by looking rather than trusting the recipe comment: the
first four bytes of the file are `hsqs`, squashfs magic. A `.raucb` really
is just a squashfs container.

## The failure that taught the most: HTTP range requests

First install attempt died at 20%:

```
20% Checking bundle failed.
LastError: ... failed to configure streaming: range requests not supported by server
```

Meanwhile the PC's `python3 -m http.server` printed six full tracebacks
(`BrokenPipeError`, `ConnectionResetError`) — which are the *symptom*, not
the cause: they're the server noticing the client hung up on it.

Why it happened. A `verity` bundle is meant to be read **in place** over
the network, never downloaded. RAUC points an NBD device at the URL, and
the kernel then treats the remote file as a block device: squashfs
superblock, then the manifest, then dm-verity hash-tree nodes, then payload
blocks — thousands of small reads, out of order. Every one is an HTTP
`Range: bytes=X-Y` request. Python's stdlib `http.server` implements plain
GET only, so it answers each one with the whole 60 MB from byte 0. RAUC
detects it didn't get what it asked for, drops the connection, retries.

Session 14's rpm feed never hit this because `dnf` downloads whole files.
Same server, same port, same directory — completely different access
pattern. Worth remembering as a class of bug: *a component can be adequate
for one consumer and structurally wrong for the next, with no change to
either side.*

Fixed by writing `scripts/serve-deploy.py`: stdlib-only, ~100 lines, serves
the same directory on the same port with `Accept-Ranges`, `206 Partial
Content`, HTTP/1.1 keep-alive (thousands of requests, one TCP connection)
and a threading server. It replaces the old one-liner for the rpm feed too.
Verified with curl before touching the Pi — explicit range, suffix range
(`bytes=-8`, which squashfs actually uses to find its trailer), mid-file
range, and the plain probe that RAUC uses to decide ranges are available.

The alternative was `scp` the bundle and install from a local path. It
works, and it would have quietly retired the streaming path we chose the
verity format for. On the Pi Zero W, whose only spare partition is `/data`
at 100 MB, "no room to stage the update you're applying" is the difference
between OTA working and not.

## The install

```
10% Determining slot states done.
20% Verifying signature done.
30% Checking manifest contents done.
40% Determining target install group done.
46% Checking slot rootfs.1 (B) done.
99% Copying image to rootfs.1 done.
100% Installing done.
```

Read that as an abort ladder: signature, then manifest, then compatible,
then slot selection — **nothing is written until 40%.** Every rejection
RAUC can make, it makes before touching the card. RAUC picked `rootfs.1`
itself; no partition was ever named on the command line.

### The pre-reboot state is the whole idea in one screen

```
Booted from: rootfs.0 (A)      <- still running the old OS
Activated:   rootfs.1 (B)      <- the new one is staged
/etc/os-release: VERSION_ID=0.1
BOOT_ORDER=B A   BOOT_A_LEFT=3   BOOT_B_LEFT=3
```

Those first two lines disagreeing *is* "an update is pending". A new OS is
fully installed and the running system is untouched; up to this point the
whole thing is undone by doing nothing.

The hashes recorded in slot B's status matched the host's `rauc info`
exactly — manifest `d7c186cc...`, image `021dbc21...`, byte count identical
— across a signature check, a squashfs container, an NBD stream and 377 MB
of SD writes. That's the payload proven end to end, not assumed.

Two smaller observations:
- **Slot A's status block is empty** (`compatible=(null)`). Not a bug: RAUC
  only records what RAUC installed, and A got there via `dd` from
  `flash-sd.sh`. That bookkeeping lives in `/data`, outside both slots.
- **The `x`/`o` marker follows `Activated`, not `Booted from`.** It shows
  the bootloader's intent, not present reality.

### After reboot

```
/proc/cmdline: ... root=/dev/mmcblk0p3 rauc.slot=B
VERSION_ID=0.2
Booted from: rootfs.1 (B) / Activated: rootfs.1 (B)
```

p3, not p2. A new OS delivered over HTTP to a running device with nobody
holding a card.

## The rollback

Read the Pi's actual boot script first
(`meta-rauc-raspberrypi/.../boot.cmd.in`) rather than assuming:

```
elif test "x${BOOT_SLOT}" = "xB"; then
  if itest ${BOOT_B_LEFT} -gt 0; then
    setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1
    setenv bootpart "/dev/mmcblk0p3"
```

Three things fall out of the source that are easy to get wrong from memory:

1. **The decrement happens before the kernel is loaded, and is `saveenv`'d
   immediately.** U-Boot spends the credit up front, so a panic two seconds
   later has already been counted. A crash cannot dodge the accounting.
2. **A zero counter isn't handled specially** — the loop just doesn't select
   that slot and falls through to the next entry in `BOOT_ORDER`. Rollback
   isn't a feature; it's what remains when the preferred slot runs out.
3. **If both counters hit zero**, both reset to 3 and the board `reset`s.
   The anti-brick clause: it can always claw back to trying something.

The counters are **credit balances, not boot counts**: "how many more times
will U-Boot attempt this slot before writing it off". Nothing in the boot
path ever pays credit back — only userspace does, deliberately.

Which makes the real design point: **a slot is guilty until proven
innocent.** Nobody detects failure. Failure is the default and the counter
drains unless something intervenes. Panic, hang, yanked power, rootfs that
mounts but whose application is dead — all identical to U-Boot, all handled
by the same three lines. You never have to enumerate failure modes.

### rauc-mark-good.service is the intervention

```ini
ConditionKernelCommandLine=|rauc.slot
After=boot-complete.target
Requires=boot-complete.target
ExecStart=rauc status mark-good
```

- `ConditionKernelCommandLine=|rauc.slot` — only runs if the boot script put
  `rauc.slot=` on the command line, so it self-skips on a non-RAUC boot. The
  boot script and the service communicate through `/proc/cmdline`.
- `Requires=boot-complete.target` — **the extension point, and the reason
  any of this is worth having.** The slot is marked good not because the
  system booted but because systemd reached that target. Hang your own
  health checks off it (`Before=boot-complete.target`) and "did the update
  work?" becomes a question your code answers, instead of the proxy "it got
  to a login prompt".

  For the Pi Zero W capstone the real condition is "a USB serial device
  enumerated and the log file is growing", not "Linux started".

### Forcing it

`systemctl mask rauc-mark-good.service` on the running slot B. `mask`
rather than `disable` on purpose: `disable` only removes the `WantedBy`
symlinks (something else can still pull the unit in), while `mask` symlinks
it to `/dev/null` so systemd cannot load it at all. The symlink lands in
`/etc/systemd/system` on **p3**, i.e. inside slot B — so slot B genuinely
becomes a bad update, exactly as if it had shipped that way. A knows
nothing about it.

Predicted from the script, then observed, with no discrepancies:

| boot | `BOOT_B_LEFT` | slot | `VERSION_ID` |
|---|---|---|---|
| 1 | 2 | B | 0.2 |
| 2 | 1 | B | 0.2 |
| 3 | 0 | B | 0.2 |
| 4 | 0 | **A** | **0.1** |

On the 4th, `BOOT_A_LEFT` read 3 — debited to 2 by U-Boot, credited back by
A's unmasked `mark-good`. The healthy round trip is invisible except by
contrast with the broken one.

Caveat on the method: masking a service is a *simulated* failure that
leaves you able to SSH in and watch. A genuinely bad update might panic
before userspace exists. The counter mechanism is identical; this version
just lets each step be observed instead of inferred.

## The unplanned discovery: identity is per-slot

Booting back into A produced:

```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

Not noise, and not a security problem — the mechanism is in poky's
`dropbearkey.service`:

```ini
ConditionPathExists=!/etc/dropbear/dropbear_rsa_host_key
ExecStart=dropbearkey -t rsa -f ${DROPBEAR_RSAKEY_DIR}/dropbear_rsa_host_key
```

The host key is generated on first boot **into `/etc`**, and `/etc` is
inside the rootfs, so it is per-slot. A generated its key after the flash;
B's rootfs arrived from the bundle with no key and generated a different
one. Changing slots changes the machine's cryptographic identity, and SSH
correctly refused to continue.

Generalised, and this is the part that bites real products:

> **Anything generated at first boot and stored in the rootfs is per-slot,
> and is silently destroyed by every update.**

SSH host keys merely announced themselves. The same goes for
`/etc/machine-id`, pairing tokens, licence files, TLS client certs, and any
app state under `/etc` or `/var`. On a desk it's a warning. On a fleet,
every updated device becomes unrecognisable to your infrastructure — and
every rollback changes its identity *back*, which is worse because it's
intermittent.

The fix is the partition we made in notes/16 and have not yet used for
anything: `/data`, outside both slots, untouched by updates. `dropbearkey`
even has the hook ready — a second `ConditionPathExists` on
`/var/lib/dropbear` and an overridable `DROPBEAR_RSAKEY_DIR` — so a small
systemd drop-in relocating it to `/data` fixes it permanently.

**Not done yet. Written down as the next task, deliberately, rather than
bolted on at the end of a session.**

## What Phase 5 actually bought

The board now updates itself over the network and un-updates itself when
the update is bad, and every step of both is inspectable from a shell. What
is *not* covered, and should not be forgotten:

- **`config.txt`, `cmdline.txt`, the device tree, our overlays, the GPU
  blobs and U-Boot itself are shared and not OTA-updatable.** Changing any
  of them still needs the card in your hand. Updating a bootloader over the
  air is the genuinely dangerous case — a half-written bootloader is an
  unbootable board — so it normally gets its own redundancy scheme or is
  declared out of scope. Ours is declared out of scope.
- **The slot filesystem doesn't grow to fill its partition** by default, so
  p3 holds a 360 MiB filesystem in a 468 MiB one. Fixable in one line, not
  with a hook as first assumed — `img_to_fs_handler` in RAUC's
  `update_handler.c` ends with:
  ```c
  if (dest_slot->resize && g_strcmp0(dest_slot->type, "ext4") == 0)
          ext4_resize_slot(dest_slot, &ierror);
  ```
  `resize` is a per-slot boolean in `system.conf` (default false), so
  `resize=true` under each `[slot.rootfs.N]` runs `resize2fs` after every
  install. Not enabled yet — it changes the image, so it belongs with the
  next image change rather than on its own.
- **Per-slot identity**, above.

## An install is a raw block write — both edges of the same knife

Worth stating plainly, because it explains two things at once.
`img_to_fs_handler` calls `write_image_to_dev()`: the payload goes onto
`/dev/mmcblk0p3` byte-for-byte. Not a merge, not rsync, not a package
upgrade. Whatever was on the slot stops existing along with its filesystem.

Contrast session 14: `dnf install less` merged into a running system, so
the outcome depended on that device's history. An A/B image install has no
such dependency — any two devices that install this bundle end up
byte-identical regardless of what was done to them first. No configuration
drift, which is the reason to prefer it for a fleet you can't inspect.

The uncomfortable half: this is the *same* mechanism as the lost SSH host
key. Identical operation, opposite value judgement — it erases our
deliberate sabotage (good) and the key the device generated for itself
(bad). You can't have one without the other. "The slot is defined entirely
by the image" and "anything the device created for itself is gone" are one
sentence read from two sides. So the host-key problem isn't a bug to patch;
it's state living in the wrong place.

Not touched by an install: slot A, `/data`, `/home`, the FAT boot
partition. And `BOOT_x_LEFT` is reset via `fw_setenv` as a separate step —
bootloader state isn't part of the image either.

Practical consequence: **the fix for a bad slot is another install.** One
`rauc install` over the broken slot restores it, mask symlink and all, with
no physical access.

## Next

- Move the dropbear host key (and audit `/etc/machine-id`) onto `/data` —
  the real lesson of this session.
- `resize=true` on both rootfs slots (see above). Bundle it with the
  dropbear change, since both touch the image.
- Optional, on merit and still not done: pin `boot_targets` to `mmc` —
  see the end of notes/16.
- Phase 6: the Pi Zero W capstone.

## State the Pi was left in

Running slot A (0.1), healthy. Slot B holds 0.2 with `BOOT_B_LEFT=0` and a
masked `rauc-mark-good`, so it will keep booting A indefinitely — a stable
place to stop. One `rauc install` puts B right whenever it's wanted.
