# Session 7 — systemd: flipping the init manager + our first service unit

Goal: INIT_MANAGER = "systemd", watch session 3's dropbear class
machinery take the other branch, ship our own unit. VERIFIED 2026-07-18:
PID 1 = systemd, playground-pulse ran at boot (LED visibly switched from
timer blink to heartbeat at multi-user), dropbear socket-activated.
**Phase 4 complete.**

## The flip

- local.conf: INIT_MANAGER = "systemd" (overrides poky.conf's "?=").
  Pulls in init-manager-systemd.inc which appends "systemd usrmerge" to
  DISTRO_FEATURES + points VIRTUAL-RUNTIME_init_manager at systemd
  (that's what packagegroup-core-boot follows to pick PID 1).
- usrmerge = merged /bin -> /usr/bin layout systemd requires; relocates
  files in most packages => the biggest rebuild since build #1. The
  blast-radius spectrum, now fully measured first-hand:
  config.txt edit = 3 tasks; kernel .cfg = 14; DISTRO_FEATURES = ~all.

## Our unit (playground-pulse)

- recipes-apps/playground-pulse: .service file + 15-line recipe.
  inherit systemd + SYSTEMD_SERVICE:${PN} = the unit name; class finds
  it in ${systemd_system_unitdir} (/usr/lib/systemd/system with
  usrmerge), packages it, and ENABLES it at rootfs-assembly time — no
  first-boot systemctl enable.
- Units are declarative (vs sysvinit case-statement scripts). Ours:
  Type=oneshot + RemainAfterExit=yes (status shows "active (exited)"),
  ExecStart=/bin/sh -c 'echo heartbeat > .../trigger' (sh -c because
  ">" is shell syntax), WantedBy=multi-user.target.
- Continuity: overlay (notes/11) boots the LED on "timer"; this service
  switches it to "heartbeat". The visible transition mid-boot = the
  service executing, observable without a terminal.

## Seen on target

- cat /proc/1/comm -> systemd.
- Socket activation live: dropbear.socket holds :22, Triggers: shows
  dropbear@<conn-tuple>.service — the CURRENT ssh session is itself a
  unit, spawned per connection. Accepted/Connected counters. Session 3's
  "inherit update-rc.d systemd" question fully closed: same recipe,
  other DISTRO_FEATURES branch, and it ships .socket units instead of
  an init script.
- journalctl -u <unit> = per-unit log slice; structured logging replaces
  "grep /var/log/messages and hope".
- systemd-analyze: 3.6s kernel + 6.7s userspace = 10.3s to multi-user.
  blame TOP entries were FIRST-BOOT-ONLY work: ldconfig 3.3s (ld cache
  build), machine-id-commit, dropbearkey 860ms (host key gen — the cost
  ssh-pregen-hostkeys removes; capstone lever confirmed with a number).
  Reboot #2 is the steady-state measurement.

## The wrong-clock lesson

Status said "since Thu 2025-05-29 ... 1 year 1 month ago". Pi 5 RTC has
no battery fitted -> clock starts at systemd's compiled-in floor date;
service start recorded under that wrong time; later timesyncd corrected
the clock to real 2026 (hence the absurd relative age). Embedded gotcha:
log timestamps from before time-sync lie. Fixes: RTC battery, or accept
+ know it. Verify current clock with `date`.

## Misc

- busybox head wants `-n 15`; GNU's bare `-15` shorthand doesn't exist
  there. Target-side coreutils are busybox applets — flags are the
  subset documented in --help, not the GNU manpage.
- systemd-analyze ships as its own package (systemd's PACKAGES split,
  systemd_255.bb:422) — added to playground-image IMAGE_INSTALL.
