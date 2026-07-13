# Session 4 — Kernel config: menuconfig, fragments, first .bbappend

Goal: enable CONFIG_IKCONFIG_PROC so the kernel exposes its own build
config at /proc/config.gz on the target. Self-proving change: before,
`zcat /proc/config.gz` fails; after, the kernel testifies about itself.

## The mechanism

- `bitbake -c menuconfig virtual/kernel` — the kernel's own Kconfig UI run
  inside the recipe env. `virtual/kernel` is a PROVIDER SLOT, not a recipe:
  machine conf picks PREFERRED_PROVIDER_virtual/kernel = linux-raspberrypi.
  (Kconfig trivia: ESP-IDF, Zephyr, U-Boot, buildroot all adopted the
  kernel's Kconfig — menuconfig skills transfer everywhere.)
- Changes land only in the build dir's .config = EPHEMERAL. Capture:
  `bitbake -c diffconfig virtual/kernel` emits fragment.cfg containing
  just the changed CONFIG_ lines.
- A `.cfg` in a kernel recipe's SRC_URI is a config fragment, merged at
  do_configure. meta-raspberrypi ships its own tweaks the same way
  (default-cpu-governor.cfg etc. in linux-raspberrypi.inc).
- Our first .bbappend (meta-playground/recipes-kernel/linux/
  linux-raspberrypi_%.bbappend): FILESEXTRAPATHS:prepend for our files/,
  SRC_URI += the fragment. "%" matches any recipe version. Directory
  must mirror the original layer's recipe path (BBFILES glob finds it).
  bbappends are hand-written (short, declarative) — no generator, except
  devtool finish which emits one when finishing into a non-owning layer.

## What went wrong (the good lesson)

Intended order: menuconfig -> diffconfig -> cp fragment -> THEN bbappend.
Actual: the bbappend landed first, referencing ikconfig.cfg before it
existed -> **parse failure across ALL kernel versions** (file:// SRC_URI
entries are checksummed at PARSE time; % made it hit 6.1/6.6/6.12 alike)
-> diffconfig itself couldn't run (generator locked out by the reference
to its own output). Untangle: hand-wrote the 2-line fragment (identical
to what diffconfig emits — its output is just the changed CONFIG_ lines).

Rules extracted:
- A .bbappend and the files it references must land TOGETHER.
- file:// existence is a parse-time contract; one dangling reference in
  any layer poisons the whole parse.
- The error's "paths searched" list = FILESPATH laid bare, including
  machine/arch subdirs (raspberrypi5/, aarch64/, rpi/) for per-machine
  file variants.
- menuconfig = discovery tool ('/' to search, option help shows
  dependencies); diffconfig = just the scribe.

## Verify (after image rebuild + reflash)

```bash
bitbake-layers show-appends | grep -A1 linux-raspberrypi_6.6
bitbake -e virtual/kernel | grep ikconfig
bitbake playground-image          # kernel recompiles — tens of minutes
# on the Pi:
zcat /proc/config.gz | grep IKCONFIG
```
