# Session 13 — state in the wrong place: the host key, and slot geometry

Follows notes/17, which closed Phase 5 but ended with a bug written down
rather than fixed: switching slots changed the board's SSH identity. This
session fixes it, turns on `resize=true` while we're rebuilding anyway, and
runs into a bootstrapping problem that turns out to be the most transferable
thing here.

Status: **DONE.** Verified on target 2026-08-16, in both directions.

## The bug, stated properly

Last session's `REMOTE HOST IDENTIFICATION HAS CHANGED!` was not an SSH
problem. Dropbear generates a host key on demand and stores it in
`/etc/dropbear`, which is inside the rootfs. A RAUC install is a raw block
write over the whole slot. So:

- slot A and slot B generated their keys independently — the board has two
  identities and swaps between them,
- and every update to a slot destroys that slot's key permanently.

The general form, which is what actually matters:

> **Any state a device generates for itself at runtime and keeps in the
> rootfs is per-slot, and is destroyed by every update.**

Host keys, `/etc/machine-id`, TLS certs, pairing tokens, licence
activations. The answer is never "make the update gentler" — it's to move
the state off the slot. We already had the place: `/data` (p5), which
`system.conf` has declared as `data-directory=/data/` since session 11 and
which no install touches.

## The fix, and the seam upstream left us

Both dropbear units already read the key path from a config file:

```
Environment="DROPBEAR_RSAKEY_DIR=/etc/dropbear"     <- default
EnvironmentFile=-/etc/default/dropbear              <- read second, wins
```

That's in `dropbearkey.service` (the generator) and `dropbear@.service`
(the per-connection server) alike. So one line moves both:

```
DROPBEAR_RSAKEY_DIR=/data/dropbear
```

We **append** that to poky's `/etc/default/dropbear` rather than shipping
our own copy, because `rootfs-postcommands.bbclass` also edits that file
during image assembly — `allow-root-login` / `allow-empty-password` (which
`debug-tweaks` enables for us) sed the `DROPBEAR_EXTRA_ARGS` line to drop
`-w` and add `-B`. Those seds are anchored on `^DROPBEAR_EXTRA_ARGS=`, so an
unrelated variable is invisible to them. Shipping our own copy would have
meant silently taking ownership of a file two other mechanisms edit. The
built rootfs confirms both survived:

```
DROPBEAR_EXTRA_ARGS=" -B"
DROPBEAR_RSAKEY_DIR=/data/dropbear
```

### The half the config file can't do

```
ConditionPathExists=!/etc/dropbear/dropbear_rsa_host_key
ConditionPathExists=!/var/lib/dropbear/dropbear_rsa_host_key
```

**Conditions take a literal path.** systemd does not expand
`$DROPBEAR_RSAKEY_DIR` here — environment belongs to `[Service]`, and this
is `[Unit]`, evaluated before any service environment exists. Move the key
and both conditions are true forever, so the generator would run on every
single SSH connection.

It wouldn't clobber the key, at least. `dropbearkey` calls
`signkey_generate(..., skip_exist=0)`, which writes a temp file and then
`link()`s it into place; `EEXIST` with `skip_exist=0` is a hard failure
(`gensignkey.c`). So the key survives and the unit fails, quietly, forever.
A permanent silent failure is arguably worse than a loud one — which is
exactly why the condition has to move *with* the key.

Hence a drop-in, `dropbearkey.service.d/persistent-host-key.conf`:

```
[Unit]
ConditionPathExists=
ConditionPathExists=!/data/dropbear/dropbear_rsa_host_key
RequiresMountsFor=/data
```

The bare `ConditionPathExists=` is the important character. An empty
assignment **resets** a list-valued directive; without it ours would be
appended, and conditions are ANDed, so the unit would additionally demand
that `/etc/dropbear` and `/var/lib/dropbear` be empty. That reset idiom is
what lets drop-ins subtract rather than only add.

### Two packaging details that cost time

- **`FILES:${PN} += "${systemd_system_unitdir}/dropbearkey.service.d"`** is
  required. Most recipes get the systemd unit dir for free; dropbear does
  not. `systemd.bbclass` adds unit files to FILES one at a time by parsing
  `SYSTEMD_SERVICE` and following `Also=`, so `FILES:dropbear` literally
  names `dropbear.socket`, `dropbear@.service` and `dropbearkey.service`. A
  directory invented alongside them matches nothing and fails
  `do_package_qa` with "installed but not shipped".
- **`${WORKDIR}`, not `${UNPACKDIR}`.** Scarthgap still unpacks SRC_URI
  straight into WORKDIR; the split is a styhead-and-later thing.

### Correction to notes/17

notes/17 says the key is generated "at first boot". It isn't.
`dropbearkey.service` has **no `[Install]` section** — systemd reports it as
`static`, meaning it cannot be enabled and nothing starts it at boot. It is
pulled in by `Wants=dropbearkey.service` in `dropbear@.service`, i.e. on the
**first incoming SSH connection**. Same consequence, different trigger. The
journal shows it: `Starting SSH Key Generation...` one second before the
shell prompt appeared.

(`dropbear.socket` does have `Also=dropbearkey.service` in `[Install]`, which
is what makes the "runs at boot" reading plausible — but `Also=` only affects
what `systemctl enable` touches, and enabling a unit with no `[Install]`
section does nothing.)

## resize=true, and why it's not one line

An install is a raw block write of the `.ext4` artifact, so a slot ends up
with a filesystem exactly as big as the one Yocto built — 327 MiB in a 468
MiB partition, with the remainder unreachable. RAUC will fix that itself:

```c
if (dest_slot->resize && g_strcmp0(dest_slot->type, "ext4") == 0)
        ext4_resize_slot(dest_slot, &ierror);
```

`resize` is a per-slot boolean in `system.conf`, default false. So the config
change is genuinely two lines. Getting it to *work* needed two more things,
and both are instances of the same rule.

## The rule this session actually taught

> **An update mechanism's capabilities live in the deployed system, not in
> the update.**

The bundle is inert data. The running slot is the machine. Three things had
to line up **on the installing side**, and the config change only covers the
first:

| requirement | lives where | had it? |
|---|---|---|
| `resize=true` for the target slot | running slot's `/etc/rauc/system.conf` | hand-edited |
| daemon has re-read that config | `systemctl restart rauc` | needed doing |
| the `resize2fs` **binary** | running slot's rootfs | **no** |

The daemon point is easy to forget: `rauc install` is a thin client talking
to `rauc.service` over D-Bus, and the daemon parsed `system.conf` when it
started. Editing the file changes nothing until it restarts.

The third was a real failure, at 99%, after writing all 377 MB:

```
Failed updating slot rootfs.1: Failed to run resize2fs:
Failed to execute child process “resize2fs” (No such file or directory)
```

`ext4_resize_slot()` doesn't use a library — it builds an argv and execs the
binary. `e2fsprogs-resize2fs` is a separate package from
`e2fsprogs-e2fsck`, which was the only one we had. Adding it to
`playground-image.bb` puts it in the *new* image, i.e. slot B — but the
process that needs it runs on slot A. **No bundle can retroactively give the
installing slot a capability it lacks.**

`rauc`'s RDEPENDS can't help either, and shouldn't: resize is optional and
per-slot, so whether this device needs `resize2fs` is a fact about *this
device's* `system.conf`. That makes it an image decision, which is why the
package is named explicitly in `playground-image.bb` with a comment saying
why.

### How we got out of it

`dnf install e2fsprogs-resize2fs` — session 14's package feed, served by the
same `scripts/serve-deploy.py` that was already serving the bundle. Needed
`bitbake package-index` on the PC first, because the repodata was from July
and the rpms were from tonight. A satisfying loop to close: the feed we built
three sessions ago is what unblocked the updater.

Real products avoid the situation by shipping the whole OTA toolchain in the
**very first factory image**, used or not. You can add packages to a fleet;
you can't add them to the thing that does the adding. This gap is invisible
once every slot is new enough, which means it only ever appears at the
transition — exactly when nobody is testing.

## Verified on target

Install into B from A, reboot, then install into A from B, reboot.

```
                        before        after
slot B filesystem       327.4M   ->   428.4M     resize
slot A filesystem       443.0M   ->   428.4M     see below
/etc/os-release              0.1/0.2 ->  0.3     both slots
```

Slot B, freshly booted:

```
root=/dev/mmcblk0p3  rauc.slot=B
/data/dropbear/dropbear_rsa_host_key   -rw-------  805 bytes, created post-boot
Fingerprint: SHA256:D/RY/rPySEmCWyG+TsITiU7pDidoB80La3p0iYNpk58
dropbearkey.service: Loaded: loaded (...; static)   <- confirms no [Install]
                     Drop-In: .../dropbearkey.service.d
```

That the fingerprint SSH negotiated equals the fingerprint of the file on
`/data` is not a tautology — it proves the *server* resolved
`DROPBEAR_RSAKEY_DIR` the same way the *generator* did. Had only the
generator picked it up, dropbear would have made a second key in
`/etc/dropbear` and served that, and everything would have looked fine while
the bug persisted.

Then slot A, after the reverse install:

```
root=/dev/mmcblk0p2  rauc.slot=A     VERSION_ID=0.3     df / = 428.4M
Fingerprint: SHA256:D/RY/rPySEmCWyG+TsITiU7pDidoB80La3p0iYNpk58   <- same key
/etc/dropbear/          empty
which resize2fs         /usr/sbin/resize2fs   <- from the image, not dnf
```

**`ssh yocto` connected with no warning and no prompt.** The board switched
slots and its identity did not move. That non-event is the deliverable.

The empty `/etc/dropbear/` is what makes it airtight: A's old 0.1 key was
destroyed by the block write, so there is no other key on the system that
could have been served by luck.

The reverse install also needed no hand-editing and no daemon restart — B
shipped with `resize=true` and `resize2fs` in it, so it was the ordinary
case. That is the bootstrapping gap closing behind us.

## Persistence is a property of the pair, not of an image

Worth stating because it nearly caused a false negative. After booting B we
could not yet test the round trip, because slot A was still 0.1 and had
neither the drop-in nor the config line. Booting A then would have served
A's own old key and fired the warning again — looking exactly like the fix
failing.

The fix only holds once **both** slots agree where the key lives. Which is
why the honest test is install → boot → install the other way → boot, and
why "it works on the new image" is not the claim being made.

## Slot A got smaller, and that's the good outcome

```
A before 443.0M   ->   A after 428.4M   ==   B after 428.4M
```

A was bigger because it was never a bundle install — it was flashed from the
`.wic`, where `wic` ran `mkfs.ext4` sized to the partition. B was small
because a bundle payload is the bare `.ext4` artifact, sized to its contents.

Both now sit at 428.4M, below the old 443.0M, because **growing a filesystem
is not the same as creating one that size**: `resize2fs` bolts block groups
onto a filesystem whose geometry (inode density, reserved GDT blocks) was
fixed at 327 MiB, which costs more metadata than a fresh `mkfs` at 468 MiB.
~15 MiB, about 3%. Reasoned, not measured — `dumpe2fs -h` on both would
confirm it.

We traded ~15 MiB on A for ~100 MiB on B, and got something better than
either: **the slots are now identical in construction.** Previously A and B
were built by different tools and differed in a way nobody had noticed.
Slots that are supposed to be interchangeable finally are.

## machine-id: measured, understood, not fixed

Before any of the above, ten seconds of measurement, because notes/17 had
*claimed* machine-id has the same problem without checking:

```
slot A:  efab8e5edbd3486c8797823dadfca81a
slot B:  4e659ad3c6bb42f8a165f8bc784a05c2
```

Different, as suspected. Poky ships an empty `/etc/machine-id`
(`rootfs-postcommands.bbclass:231`) and lets systemd fill it in at first
boot, into the rootfs. Same bug class.

Not cosmetic either: `systemd-networkd`'s DHCP DUID is derived from
machine-id by default, so the server sees a different client and can hand
out a **different IP** after a slot switch. Journal storage lives at
`/var/log/journal/<machine-id>/`, and anything using
`sd_id128_get_machine()` inherits the problem.

**Not fixed, and there is no drop-in-sized version.** PID 1 reads
`/etc/machine-id` before it mounts anything, `/data` included, so the file
must already be correct at hand-off. That means an initrd doing a bind
mount, or baking one ID into the image (which makes every device identical —
worse). The practical mitigation for the capstone is to remove the
*consequence* rather than the cause: pin the DHCP client identifier to the
MAC instead of the DUID. That's a Phase 6 networking decision.

## Free confirmation of a notes/17 claim

Slot B was left deliberately sabotaged last session — `rauc-mark-good`
masked, `BOOT_B_LEFT=0`. Nobody unmasked it. After the install:

```
ls -l /mnt/b/etc/systemd/system/rauc-mark-good.service
  -> No such file or directory
```

The mask symlink lived in the slot's rootfs, so the block write took it. The
"an install is a raw block write, the slot is defined entirely by the image"
claim from notes/17, observed rather than read out of C. A bad slot really
does self-heal from one install, with no physical access.

Also spotted while poking at `/data`: `central.raucs`, RAUC's own persistent
slot-status file, there because of `data-directory=/data/`. RAUC has been
practising what we only just started preaching, since session 11.

## Next

- Phase 6: the Pi Zero W capstone. `Requires=boot-complete.target` is where
  a real health check goes — "the logger is actually logging" — and DHCP
  client identity is now a known item to settle there.
- Optional, on merit and still not done: pin `boot_targets` to `mmc`, see
  the end of notes/16.
- Still open from earlier: the CA cert's `notBefore=Jan 1 1970`, which
  `scripts/rauc-gen-keys.sh` doesn't ask for.

## State the Pi was left in

Running slot A at 0.3, healthy, both slots at 0.3 and byte-identical in
construction. Host key on `/data`, shared. `BOOT_ORDER`/counters normal. The
`dnf`-installed `resize2fs` on the old A is gone, replaced by the image's
own copy. Nothing masked, nothing hand-edited surviving — the only manual
change made this session (`resize=true` in A's running `system.conf`) was
overwritten by the reverse install with the same setting from the image.
