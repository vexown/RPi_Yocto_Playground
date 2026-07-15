# Session 5 — Device trees, part 1: what they are + a dtparam

Quick session. Goal: first contact with device trees using the simplest
possible hardware (the green ACT LED), before writing a real overlay.
Result: LED heartbeats from power-on, VERIFIED 2026-07-16.

## What a device tree even is

- On x86, hardware is discoverable (PCI/USB/ACPI announce themselves).
  On an ARM SoC, peripherals are just registers at fixed addresses —
  the kernel can't probe for them. It must be TOLD what exists.
- Pre-2012 that knowledge was hardcoded C "board files" in the kernel,
  one per board. Didn't scale; Linus blew up; the fix was moving the
  hardware description OUT of code INTO data: the device tree.
- .dts (text, tree of nodes with properties) --dtc--> .dtb (binary blob)
  handed to the kernel at boot by the bootloader. One generic ARM kernel
  binary + per-board .dtb = boots on thousands of boards.
- The kernel walks the tree; each node's `compatible` string picks the
  driver to bind; the driver reads the node's properties for details
  (which GPIO, which address, which default trigger...).
- MCU-world analogy: it's the pin-mux table / board config header, but
  decoupled from the compiled firmware.

## Seen live on the target

- `/proc/device-tree` = the booted DT exposed as a filesystem: dirs are
  nodes, files are properties. Values are raw bytes: strings end in NUL
  (that's why `cat` glues output to the prompt — and why two globbed
  properties printed as "heartbeatnone"), numbers are big-endian binary
  (use hexdump -C).
- `/sys/class/leds/ACT` exists ONLY because a DT node told the leds-gpio
  driver "LED on this GPIO, label ACT". No node -> no sysfs entry, even
  though the physical LED is still soldered there.
- Runtime rewire (ephemeral, like menuconfig's .config was):
  `echo heartbeat > /sys/class/leds/ACT/trigger`. The trigger menu only
  lists heartbeat because CONFIG_LEDS_TRIGGER_HEARTBEAT=y — checked via
  our own /proc/config.gz from session 4. Default was [mmc0] (SD card
  activity), straight from the node's linux,default-trigger property.

## Persisting it: dtparam (the Pi's DT patching trick)

- Pi firmware PATCHES the base .dtb before handing it to the kernel,
  steered by config.txt. `dtparam=X=Y` twiddles a named knob that the
  .dtb declares in its `__overrides__` node; `dtoverlay=` is the same
  machinery for whole .dtbo fragment files (next session: write one).
- Yocto side: meta-raspberrypi's rpi-config recipe owns config.txt and
  appends RPI_EXTRA_CONFIG verbatim (rpi-config_git.bb:304 is literally
  `printf "${RPI_EXTRA_CONFIG}\n" >> $CONFIG`). Added to local.conf:
  `RPI_EXTRA_CONFIG = "dtparam=act_led_trigger=heartbeat"`.
- Gotcha: setup-yocto.sh installs conf-templates/local.conf only on
  FIRST init — after editing the template, refresh the build dir copy
  by hand (cp conf-templates/local.conf $BUILD_DIR/conf/local.conf).

## Blast radius lesson (vs session 4's kernel fragment)

Sstate summary: Wanted 3 / Missed 3 / Current 1796; 3804 of 3810 tasks
skipped. Changing RPI_EXTRA_CONFIG only re-hashed rpi-config's tasks +
image assembly — config.txt sits at the very edge of the dependency
graph. Same signature mechanism as the kernel .cfg change (14 tasks,
kernel recompile, tens of minutes), wildly different cost. WHERE a
variable sits in the graph determines what a change costs.

(The "do_compile is tainted" WARNING is still session 4's menuconfig
taint stamp; harmless, clears next time the kernel workdir is cleaned.)

## Verify

```bash
# on the Pi after reflash — DT default, before anyone touches sysfs:
grep -r . /proc/device-tree/leds/*/linux,default-trigger   # -> heartbeat
```

VERIFIED 2026-07-16: ACT trigger = heartbeat from boot, LED thumping.

## Reading the whole tree (optional toolbox)

- Decompile the deployed blob:
  `dtc -I dtb -O dts tmp/deploy/images/raspberrypi5/bcm2712-rpi-5-b.dtb`
  — few thousand lines; skim once for shape (memory map, compatible/reg/
  status properties, __overrides__ = the dtparam menu), then treat it
  like a schematic: search, don't read.
- Decompile the LIVE tree (shows firmware patches + injected RAM size,
  MAC, serial — things no .dtb on disk contains):
  `ssh yocto 'tar -C /proc -cf - device-tree' | tar -xf - -C /tmp/dt-live`
  then `dtc -I fs -O dts /tmp/dt-live/device-tree`.
- Don't diff base vs live wholesale — dtc orders nodes differently per
  input format; grep for the node you care about.
