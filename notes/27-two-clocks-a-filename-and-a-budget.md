# 27 — Two clocks, a filename, and a budget

2026-10-03. Short session, almost all of it on the host. Two of the three
items designed at the end of session 26 are built, tested and on hardware;
the hotspot test and the operator menu are not started.

## 0. A working arrangement, before any of the work

Set up `~/claude_context/` on this PC, mirroring the work laptop: a folder
outside the repo holding captured command output, scratch documents and
helper scripts. The problem it solves is narrow and was costing real time —
the division of labour here is that the user runs anything touching
hardware, a build or the network, so the only way results were being seen
was copy-pasting terminal output back by hand. That truncates, and the
interesting part is usually what already scrolled away.

`cap <label> <command>` runs a command normally and tees it into
`logs/<timestamp>-<label>.log`. The one design decision worth recording:
it runs the command under `script`, not through a pipe. A pipe is not a
terminal, so libc switches stdout to 4 KiB block buffering and a long
command writes *nothing* to the log until a buffer fills — useless for
watching a build. It also breaks anything interactive. `script` allocates a
real pty, and `-f` flushes every write, so a log is readable while the
command is still running. Captures are stored raw and rendered clean on the
way out by `readlog`; filtering on the way in loses information permanently.

Nothing from that folder enters the repo. It is `chmod 700` and outside
every repo, because captures can contain whatever the target device printed.

Two bugs in those helpers, both found by using them:

- `readlog` **deleted a line of real output**. A pty can emit `\r\r\n`, and
  the carriage-return collapse rule `s/.*\r//` matched to the last CR after
  only one had been stripped, wiping the line. It ate an ssh error message.
  Fixed to strip all trailing CRs, with a six-case regression test.
- `board-state` reported `(no /var/log/serial-logger)` for a directory that
  existed and was being written to, because BusyBox `ls` rejects
  `--time-style=full-iso` and the `||` fallback fired. That false negative
  produced a wrong hypothesis (see §3).

Both are the same class of failure and the worse one of the two possible:
a tool that reports absence when it means "my command failed".

## 1. Why ssh refused a board it had trusted for weeks

`board-state` failed instantly with `Host key verification failed.` while
connected to the address the board had been reachable at all along.

The cause is the thing worth understanding. `known_hosts` is not a list of
trusted keys; it is a table of **bindings**, name → key. The question ssh
asks is never "have I seen this key?" but "is this the key recorded for the
name I typed?". If it were the former, anyone who got you to accept their
host key once — any VPS, any shared box — could then present it from
anywhere and be believed. Recognising a key proves only that someone holds
its private half; the binding to a name is what carries meaning.

So `-o HostKeyAlias=rpi0-logger` changes the lookup name, and that alias had
never been populated on this machine. The existing entry was bound to the
address and was never consulted. `BatchMode=yes` then turned what would have
been a prompt into an immediate failure.

Both flags were ours. `BatchMode` stays — a script that hangs waiting for
input inside a capture is worse than one that fails in a second — and
meeting this on the LAN was better than meeting it mid-hotspot-test.

The alias exists because `Host rpi0` pins `HostName` to the LAN address, so
`ssh rpi0` is simply dead on a hotspot, and connecting to a freshly
discovered address prompts every time. A prompt you see at every new site is
a prompt you learn to accept, which protects nothing. `HostKeyAlias` fixes
the verification name while the address floats, so one entry follows the
board anywhere. Added to the `Host rpi0` block in `~/.ssh/config`.

Details recorded because they were checked rather than assumed:

- `CheckHostIP` defaults to **no** on OpenSSH 9.6, so `find-board.sh`'s
  `-o CheckHostIP=no` is redundant on this host (harmless, still correct on
  older ones).
- A `known_hosts` line can carry several comma-separated names; hashing
  splits it into one hashed line per name and lookup still works for each.
- `HostKeyAlias` is used "when looking up **or saving**" the key, which
  makes the post-reflash recovery two commands, not four — `ssh-keygen -R`
  the alias and accept once. An earlier instruction here padded that with
  two steps that do nothing, and the user was right to object.

## 2. What the board actually does at boot

Measured across three boots, in monotonic time, which is the only honest
clock before NTP:

| | boot A | boot B | boot C (post-flash) |
|---|---|---|---|
| logger starts | — | 18.85 s | 19.50 s |
| NTP sync | 18.19 s | 20.34 s | 21.19 s |

Session 26's ~18.8 s for the logger was correct; a guess here that it had
really been the network was wrong.

The important finding is in boot A versus boot B: same card, same network,
four minutes apart, and NTP landed *before* the logger on one and *after* on
the other, because wifi associated at different speeds. The filename is
therefore not reliably wrong — it is **sometimes right**. Nondeterministic
naming is a worse bug than consistent naming, and it is a stronger argument
for fixing the clock than for ordering the unit.

Both bad-name forms were found on the card at once:

- `session_ttyUSB0_2025-05-29_…` — the image build date, written on a first
  boot after a reflash, before `/var/lib/systemd/timesync/clock` exists.
- `session_ttyUSB0_2026-10-03_14-21-50` where the truth was ~14:22:55 — the
  last-run time, restored from that file on every later boot.

So the error equals however long the board was off. Session 26's "May 2025"
was right for the fresh-flash case and incomplete for the other; a
correction issued mid-session claiming it was simply wrong was itself wrong.

## 3. Where the captures live, and how long the disk lasts

`board-state`'s false negative (§0) briefly supported a hypothesis that
`/var/log` was a tmpfs and every capture was being destroyed at each reset —
which would have mattered, since the board resets whenever the harness is
plugged in. It is not. The decisive evidence is `/proc/<pid>/fd`, which is
the kernel's own answer and is immune to symlinks and mount namespaces:

    fd 4 -> /var/log/serial-logger/session_ttyUSB0_….log

`/var/log` is a real directory on the rootfs; only `/var/volatile` is tmpfs.
Captures persist.

What the same look found instead is a real problem:

    /dev/root   100.2M total   62.9M used   29.5M available

and a capture growing at ~77 bytes/sec — about 6.7 MB/day, so **roughly four
days to a full rootfs**. A full rootfs on an unattended logger is not
degradation; it is a board that may not have room to let you ssh in and fix
it.

The 100 MB is the *partition*, not the card. Yocto sizes the rootfs to its
content times `IMAGE_OVERHEAD_FACTOR` (1.3 by default) plus
`IMAGE_ROOTFS_EXTRA_SPACE` (0), and we set neither. The `.wic` is written to
the card as-is, so the remainder of the card is unallocated; Pi OS expands on
first boot, Yocto deliberately does not.

Also noted: `/data` is a plain directory on the rootfs, not a mounted
partition — `rpi0-logger-image.bb` says "no A/B layout on this board". The
dropbear key at `/data/dropbear` therefore persists across reboots via the
rootfs, and the bbappend's A/B reasoning is inherited from the Pi 5 work and
is inert here.

## 4. The two changes

### The filename corrects itself

A `timerfd` on `CLOCK_REALTIME` created with `TFD_TIMER_CANCEL_ON_SET`,
added to the `poll()` loop that already existed. The timer is never meant to
fire — an absolute deadline a year out is a formality. What we want is the
kernel *cancelling* it when something **steps** the wall clock, which
arrives as `read()` returning `ECANCELED`.

The insight is that the right time is not needed when the file is opened. It
is needed eventually, together with how long ago the open was:

    true_start = realtime_now − monotonic_elapsed

`CLOCK_MONOTONIC` is never stepped, which is exactly why it can be trusted
for the duration while `CLOCK_REALTIME` cannot be trusted for the date.
Then `rename()`. An open fd refers to the file, not its name, so the rename
costs no reopen and loses no bytes.

Three properties worth keeping in mind:

- It must be `TFD_TIMER_ABSTIME`; a relative timer is not invalidated by the
  clock moving, so there would be nothing to cancel.
- NTP *slews* small drift and *steps* large corrections. Only steps trigger
  cancellation — correct, since a slew never moves the clock far enough to
  change a filename.
- The timer must be re-armed after every cancellation, or only the first
  step is ever noticed.

Ordering the unit `After=time-sync.target` was the obvious fix and the wrong
one: it puts the network in front of a USB reader whose job is catching early
boot output. This adds no ordering dependency at all.

If `timerfd_create` fails it is non-fatal — logged, `clock_fd = -1`, which
`poll()` ignores. Capturing bytes matters more than a correct name.

### The logger bounds its own disk use

`SIGHUP` now rotates. That is the logrotate idiom, and it is safe to
repurpose here **only because the port is opened `O_NOCTTY`** — without it
the tty could become the controlling terminal and a carrier drop on the wire
would deliver a genuine SIGHUP, making "the cable fell out" indistinguishable
from "the operator wants a new file". That flag was already there for an
unrelated reason.

Plus a size cap (rotates through the same single code path) and a total
budget that deletes oldest-first, scoped by the `session_<dev>_` prefix so
two adapters never delete each other's work. Every deletion is reported to
the journal. Both limits live in `/etc/default/serial-logger`; 0 disables.

A bigger partition is explicitly not treated as a fix. Any fixed amount of
space loses to unbounded growth; it only moves the date.

## 5. Verified, and not

Host, against a pty — twelve checks, all passing: SIGHUP rotation, size-cap
rotation, pruning, the `-N` suffix for two rotations inside one second, and
0-means-unlimited.

Hardware, boot C, which is the case that could not be tested on the host
because stepping `CLOCK_REALTIME` needs privileges and Linux time namespaces
do not virtualise that clock:

    19.50  logging … to session_ttyUSB0_2025-05-29_18-48-36.log
    21.19  clock stepped; renamed log to session_ttyUSB0_2026-10-03_15-35-25.log
    21.19  Initial clock synchronization to 2026-10-03 15:35:26.838591

True start was 15:35:26.84 − 1.69 s = 15:35:25.1; the new name says
15:35:25. Correct to the second, and the bad name it replaced was the
build-epoch form — the bug and its fix 1.7 seconds apart in one boot.

**Not verified on hardware:** rotation and pruning. Only the clock path was
exercised on the board.

Two limits honestly stated:

- The budget is enforced at rotation boundaries, so real usage reaches
  `budget + max_file_bytes` before trimming — 15424 bytes against a 12288
  budget in the host test. Bounded, but not a hard ceiling.
- `prune_old_logs` sorts by mtime, and a file created under a wrong clock
  that then receives no data keeps a bogus mtime (observed: a correctly
  named file with a 2025-05-29 mtime, because nothing had been written yet).
  Benign — such a file is empty, so pruning it first loses nothing — but it
  is a real wrinkle in the ordering.

## For session 28

1. **The hotspot test of `find-board.sh`**, still untouched, and now second
   time carried over. Host checks done: nmap present, BOARD_MAC recorded,
   two networks in the card's wpa_supplicant conf with keys stored derived.
   Run 0 passed on the LAN — tailscale skipped, one /24 swept in 2 s, exact
   MAC hit, cache written. The `/16` VPN case that caused the rewrite can
   only be reproduced on the work laptop.
2. **Rotation and pruning on hardware.** One command each; nothing was
   flowing from the target this evening, so even an empty rotation would
   prove the path.
3. **The operator menu**, which now has real primitives to wrap rather than
   being invented alongside them.
4. **A separate partition for captures**, when the product answer is wanted.
   Not a substitute for the caps: the caps stop the logger misbehaving, the
   partition contains the damage when something else does. A full dedicated
   partition stops logging; a full rootfs stops the board.
