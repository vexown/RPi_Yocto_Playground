# Session 1c — First boot on the Pi 5 (2026-07-11)

It boots! `Poky (Yocto Project Reference Distro) 5.0.19 raspberrypi5 /dev/tty1`,
root login with no password (debug-tweaks). Phase 1 complete.

## What we saw on screen vs. why

Observed: no rainbow screen, no kernel/init log scroll — just raspberry
logos, "Please wait: booting...", then the login prompt.

1. **No rainbow screen**: that colorful test pattern is a Pi 1–4 GPU
   firmware feature. The Pi 5 firmware doesn't draw it (it only shows a
   diagnostic screen when boot *fails*). Expectations calibrated for Pi 4
   and earlier don't transfer.

2. **The raspberry logos**: drawn by OUR kernel — the framebuffer console
   logo (CONFIG_LOGO; the RPi downstream kernel replaces Tux with a
   raspberry). One logo per CPU core → four raspberries = quad-core
   kernel up and running. Seeing them proves kernel + display driver work.

3. **No kernel messages on HDMI — the real lesson.** Our shipped kernel
   command line (bootfiles/cmdline.txt in the deploy dir):

       dwc_otg.lpm_enable=0 console=serial0,115200 root=/dev/mmcblk0p2
       rootfstype=ext4 rootwait net.ifnames=0

   The only `console=` is **serial0** — a consequence of `ENABLE_UART = "1"`
   in our local.conf. meta-raspberrypi's `rpi-cmdline.bb` recipe generates
   this line, and adds `console=serial0,115200` when UART is enabled.
   So ALL kernel and init log output went out the UART pins, where nothing
   was listening. HDMI/tty1 only ever showed what was explicitly sent to
   the virtual terminal (logos, banner, login).
   → Lesson: `console=` decides where boot logs go. Multiple `console=`
   entries are allowed; the LAST one becomes /dev/console.

4. **"Please wait: booting..."**: printed by `/etc/init.d/banner.sh` — an
   rc script from poky's `initscripts` package writing to the VT. Found it
   with: `grep -rn "Please wait" poky/meta/recipes-core/initscripts/`.

5. **Login prompt on /dev/tty1**: sysvinit's inittab spawns a getty on
   tty1 (and on the serial console). getty prints the /etc/issue banner —
   the "Poky (Yocto Project Reference Distro)..." line.

## Takeaways

- The boot chain we exercised: Pi5 ROM → SPI-EEPROM bootloader → GPU
  firmware reads FAT partition (config.txt, cmdline.txt) → loads our
  kernel Image + DTB directly → kernel mounts p2 as / → sysvinit → getty.
  No U-Boot anywhere (Pi peculiarity).
- To see kernel logs on HDMI next rebuild, append `console=tty1` after
  the serial console in the cmdline (possible from local.conf; candidate
  exercise for Phase 2 image customization).
- debug-tweaks = passwordless root. Never in production images.
