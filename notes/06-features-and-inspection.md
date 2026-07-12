# Session 3 — Feature gating & the inspection tools in anger

## Q: dropbear inherits `systemd` — but we run sysvinit?!

Great catch while re-reading dropbear_2022.83.bb. Resolution: **inherit is
unconditional, behavior is conditional.** Recipes are written once for every
distro; the init-system choice is *distro policy*, applied by the classes:

- `systemd.bbclass` — every function starts with
  `bb.utils.contains('DISTRO_FEATURES', 'systemd', ...)` and returns early
  on our build. It even actively deletes the installed unit files
  (`rm_systemd_unitdir`) so no `/lib/systemd` ships in the package.
- `update-rc.d.bbclass` — the mirror image, gated on `sysvinit` in
  DISTRO_FEATURES. This is the class that fires for us: it registers
  /etc/init.d/dropbear into the runlevels (the S10dropbear symlinks).
  If a distro has *both* features, systemd wins and update-rc.d steps aside.

Pattern to internalize: recipes describe every way the software *could*
integrate; DISTRO_FEATURES decides which paths are live. Same trick gates
x11, wayland, pam, ipv6 support all over poky.

## Q: why are wifi/bluetooth in DISTRO_FEATURES on a minimal image?

`bitbake -e dropbear | grep ^DISTRO_FEATURES=` showed wifi, bluetooth, x11,
3g, nfc... We inherited the stock list: DISTRO_FEATURES_DEFAULT
(meta/conf/distro/include/default-distrovars.inc) + poky's additions
(opengl ptest multiarch wayland vulkan, meta-poky/conf/distro/poky.conf).

**DISTRO_FEATURES = what the OS is allowed to support, not what's installed.**
It flips conditional branches in recipes that are being built anyway; it
never adds packages by itself. Our manifest still has no wpa_supplicant/bluez.

Three feature variables, three different questions:

| Variable         | Question                        | Set by                |
|------------------|---------------------------------|-----------------------|
| DISTRO_FEATURES  | what CAN this OS support?       | distro conf (poky)    |
| MACHINE_FEATURES | what does the hardware have?    | BSP (meta-raspberrypi)|
| IMAGE_FEATURES   | what goes in THIS image?        | image recipe + local.conf |

`COMBINED_FEATURES` = DISTRO ∩ MACHINE ("OS supports it AND hw has it") —
how e.g. WiFi firmware lands only where both sides agree.

Capstone note: *trimming* DISTRO_FEATURES in our own distro conf (Phase 5)
is a real optimization — less configured-in support = smaller binaries,
fewer deps, faster builds on the Pi Zero W image.

## Homework results (the three inspection commands)

1. `bitbake-layers show-recipes "*ssh*"` — **dropbear is absent!** The glob
   matches recipe *names* only; dropbear provides the ssh *role* via
   RPROVIDES, which no name search reveals. Also spotted:
   - openssh 9.6p1 available-but-unused (swap via ssh-server-openssh feature)
   - `ssh-pregen-hostkeys` — ships pre-generated host keys so first boot
     skips key generation. Dev-only as-is (shared identity!) but the concept
     is a boot-time lever for the capstone: dropbear key-gen on a Pi Zero W
     costs real seconds at first boot.
   - "(skipped: reason)" lines: recipe parsed but not buildable in current
     config — always read the reason.
2. `bitbake -e dropbear | grep ^SRC_URI=` — final value after all layers/
   appends. Extra CVE patches (CVE-2025-47203, CVE-2019-6111) vs. what the
   recipe had when the book era's branches shipped: scarthgap maintainers
   keep backporting — "LTS until 2028" made concrete.
3. `oe-pkgdata-util list-pkg-files dropbear` — 7 files; only dropbearmulti
   is a real binary (rest are symlinks; packaging can't show that — check
   with `ls -la` on target). No man pages/headers: those split into
   dropbear-doc/-dev/-dbg. See the family: `oe-pkgdata-util list-pkgs "dropbear*"`.

Gotcha of the day: `bitbake: command not found` in a fresh terminal —
bitbake is only on PATH after `source scripts/setup-yocto.sh` in *that*
terminal. Like activating a Python venv, once per terminal, every time.
