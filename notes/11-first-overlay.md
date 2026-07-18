# Session 6 — Device trees, part 2: our own overlay (playground-led)

Goal: write a real .dts overlay declaring NEW hardware — an LED on
GPIO17 (pin 11) — compile + ship it via our layer, watch the kernel
believe it. VERIFIED 2026-07-18: /sys/class/leds/playground exists,
physical LED blinking from boot, triggers + brightness all live.

## The pipeline (each stage matters)

1. **Claim** — playground-led.dts (meta-playground/recipes-bsp/
   playground-overlay/files/): `/plugin/;` marks it a fragment;
   `fragment@0` + `target-path = "/"` = graft point; node says
   compatible = "gpio-leds", gpios = <&gpio 17 0>, default trigger
   "timer". `&gpio` is an IOU — a label our file can't see.
2. **Compile** — recipe runs `dtc -@ -I dts -O dtb`. The .dtbo carries a
   `__fixups__` section: "patch the gpios phandle later". Yocto recipe
   archetype #2: deploy-class recipe (BOOT PARTITION CARGO, not rootfs
   package — inherit deploy nopackages, do_deploy -> DEPLOY_DIR_IMAGE,
   PACKAGE_ARCH = MACHINE_ARCH since a .dtbo is board cargo).
3. **Ship** — local.conf: RPI_EXTRA_IMAGE_BOOT_FILES:append
   "playground-led.dtbo;overlays/playground-led.dtbo" ("src;dest" pairs,
   same list rpi-base.inc's make_dtb_boot_files() builds for stock
   overlays) + do_image_wic[depends] += "playground-led-overlay:do_deploy"
   ([depends] = task varflag, mimics rpi-base.inc's rpi-bootfiles dep)
   + RPI_EXTRA_CONFIG gains "\ndtoverlay=playground-led" (printf expands
   the \n).
4. **Graft** — at boot the firmware: loads base bcm2712-rpi-5-b.dtb,
   applies dtparams, loads our .dtbo, resolves __fixups__ against the
   base tree's __symbols__ (gpio -> rp1_gpio: on Pi 5 the RP1
   south-bridge owns the 40-pin header — reachable over PCIe!), grafts
   the fragment, hands the MERGED tree to the kernel. Kernel can't tell
   the node was an add-on (/proc/device-tree/playground-leds/ looks
   native; its `phandle` file = firmware bookkeeping).
5. **Matchmaking** — kernel walks the tree, compatible = "gpio-leds"
   binds the generic leds-gpio driver, which reads OUR properties for
   all specifics and registers /sys/class/leds/playground.

**Core lesson: drivers are generic code; the device tree is the data
that specializes them.** Nobody wrote a "playground driver". The future
I2C-sensor version of this is the same move: driver already in kernel,
overlay node summons + parameterizes it.

## Pi 5 gotcha caught before it bit

The stock gpio-led-overlay.dts has a pinctrl fragment using brcm,pins —
bcm283x pinmux dialect. Pi 5's RP1 pin controller speaks a different
binding. We dropped that fragment entirely: leds-gpio claims the pin via
gpiolib and sets direction itself. Base dts alias `gpio: &rp1_gpio`
(bcm2712-rpi-5-b.dts:236) is why shared overlays' &gpio still works.

## sysfs demystified (the "echo somehow controls my LED" question)

sysfs files are kernel objects with store/show callbacks, not disk
files. `echo 255 > brightness` = write() syscall -> LED core
brightness_store() -> leds-gpio set op (nonzero = ON, GPIOs have no
dimmer) -> gpiolib -> RP1 driver writes a memory-mapped register (over
PCIe) -> pad drives 3.3V on pin 11 -> photons. The overlay is the map
from the name "playground" to that copper.

Triggers = kernel-side automation clipped onto any LED: timer (500ms
kernel timer), heartbeat (load-derived thump), mmc0 (storage activity —
ACT's stock trigger), cpu, panic. `none` unclips -> manual brightness.
Trigger list is identical for every LED because triggers belong to the
LED SUBSYSTEM, not the driver.

## Verify

```bash
ls /sys/class/leds                       # -> playground appeared
cat /sys/class/leds/playground/trigger   # -> [timer] from our DT default
ls /proc/device-tree/playground-leds/    # -> the grafted node, live
echo heartbeat > /sys/class/leds/playground/trigger
```

Wiring used: pin 11 (GPIO17) -> LED long leg, short leg -> ~330R -> GND
(pin 9). Active-high. Kernel creates the sysfs entry even with nothing
wired — Linux believes the tree, not the copper.

## Rebuild economics (streak continues)

No kernel rebuild for a new DT node: overlays live OUTSIDE the kernel
build. Only our new recipe's chain + rpi-config + image assembly re-ran.
Contrast: adding the .dts into the kernel's own overlays/ dir (the
alternative route) would have meant a Makefile patch + full kernel
recompile on every tweak.
