# Session 8 — our own distro conf: playground

Goal: complete the config trilogy by moving OS policy out of local.conf
into a tracked distro. VERIFIED 2026-07-25: /etc/os-release says
ID=playground / "Playground 0.1 (rpi5-era)", PID 1 still systemd —
identical OS, identity + policy now live in the layer.

## The trilogy, finally complete

- MACHINE conf (meta-raspberrypi/conf/machine/raspberrypi5.conf) —
  what the hardware IS: bootfiles, kernel, dtbs, tune flags.
- image recipe (playground-image.bb) — what's INSTALLED.
- DISTRO conf (meta-playground/conf/distro/playground.conf) — how the
  OS BEHAVES: init manager, DISTRO_FEATURES, package format, toolchain
  policy.

Same build can mix and match all three axes independently. The capstone
is exactly that: same playground distro + same-ish image, different
MACHINE (raspberrypi0-wifi).

## Why local.conf was the wrong home for INIT_MANAGER

local.conf answers "how do I build on THIS workstation" (cache paths,
debug-tweaks, disk monitors). It's per-build-directory scratch: wipe the
dir or start a second build (capstone!) and the policy silently reverts
to poky's sysvinit. A distro conf makes "this OS runs systemd" part of
the OS's tracked identity that follows DISTRO everywhere.

## Mechanics

- Activation is ONE line in local.conf: DISTRO = "playground".
  bitbake.conf does `include conf/distro/${DISTRO}.conf`, searched along
  BBPATH — and our layer.conf already appends ${LAYERDIR} to BBPATH
  (same lookup that finds classes and other conf files). No
  registration, no bbappend.
- The file itself is the "require + override" pattern most product
  distros use: `require conf/distro/poky.conf` (QA settings, uninative,
  security flags, hash equivalence, SDK naming — all inherited), then
  override only identity (DISTRO/NAME/VERSION/CODENAME/MAINTAINER) and
  policy (INIT_MANAGER = "systemd", relocated from session 7's
  local.conf entry).
- Parse-order subtlety: local.conf parses BEFORE the distro conf. That's
  why poky.conf assigns nearly everything with "?=" (set-if-unset) — it
  deliberately lets your earlier local.conf win. Our plain "=" lines
  therefore beat both poky's defaults and any stray local.conf setting:
  the distro file is authoritative for what it declares.

## What we deliberately did NOT touch

- TARGET_VENDOR stays "-poky": it's inside the toolchain triplet
  (aarch64-poky-linux) and therefore in every compiled object's task
  signature — renaming it = rebuild the WORLD for zero function. Visible
  proof: tmp/work/raspberrypi5-poky-linux/ kept its name even though the
  distro is now playground.
- DISTRO_FEATURES stays poky's set (opengl/wayland/vulkan/ptest included,
  useless on a headless Pi). Trimming is a real capstone lever, but it
  re-signs a huge chunk of the graph — this session's lesson was "move
  policy, change nothing", so the cheap rename gets measured alone.
  When we trim, it happens in playground.conf, one tracked line.

## Blast radius

Identity-only rename, DISTRO_FEATURES untouched => tiny rebuild:
essentially os-release recompiling (it bakes ID=${DISTRO},
NAME=${DISTRO_NAME}... into /etc/os-release — that's why it's the
verification file) plus rootfs/image re-assembly. Compare the running
spectrum: config.txt edit 3 tasks < identity rename < kernel .cfg 14 <
DISTRO_FEATURES flip ~everything. Position in the dependency graph, not
size of the edit, decides the cost.

## Verified on target

    cat /etc/os-release   -> ID=playground, PRETTY_NAME="Playground 0.1 (rpi5-era)"
    cat /proc/1/comm      -> systemd

Nothing else changed — which was the whole point.
