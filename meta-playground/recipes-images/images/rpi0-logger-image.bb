# rpi0-logger-image.bb — the capstone product.
#
# This is the image that replaces Raspberry Pi OS Lite on the deployed
# Pi Zero W USB serial logger. Baseline to beat: 86.9 s to a usable system
# (12.4 s kernel + 74.5 s userspace, of which NetworkManager alone was
# 43.0 s). Target: 10-15 s to working SSH + logging.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A SEPARATE RECIPE AND NOT core-image-minimal
# ---------------------------------------------------------------------------
# Because a .bbappend attaches to a recipe NAME. Nothing else. Not to a
# machine, not to a use case, not to the board the layer was added for.
# Session 14 found meta-rauc-community shipping
#
#     recipes-core/images/core-image-minimal.bbappend
#
# which added 1732 kernel modules to our Zero W build. We never asked for
# it; we asked for a layer, four months earlier, for a different board. The
# only reliable defence is to stop using the name everyone appends to.
#
# Note what this does NOT protect against: base-files_%.bbappend from the
# same layer, which rewrites /etc/fstab for the whole ":rpi" family. An
# image recipe cannot help there — the fstab is not in this recipe's name
# space. That one is fixed in recipes-core/base-files/, and the reasoning
# is worth reading: it is the same class of bug with a different remedy.
#
# ---------------------------------------------------------------------------
# WHY NOT REUSE playground-image.bb
# ---------------------------------------------------------------------------
# playground-image is the Pi 5 learning rig: RAUC A/B, package management,
# an LED heartbeat, a hello-world binary. Every one of those is either
# useless or actively costly on the Zero W. The two boards are running
# genuinely different products, and "different product" is exactly what an
# image recipe is for. They still share a DISTRO (playground), which is the
# right seam: same policy, different contents.

SUMMARY = "Pi Zero W USB serial logger — the capstone product image"
DESCRIPTION = "Boots to working SSH and USB serial logging. No desktop, \
no package manager, no OTA — a single-purpose appliance that gets \
reflashed, not updated."
LICENSE = "MIT"

inherit core-image

IMAGE_INSTALL = "\
    packagegroup-core-boot \
    e2fsprogs-e2fsck \
    dropbear \
    os-release \
    serial-logger \
    ${LOGGER_USB_SERIAL_MODULES} \
    ${LOGGER_WIFI} \
    rpi0-network \
    systemd-analyze \
    journald-size-cap \
    "

# --- The USB serial drivers -------------------------------------------------
#
# Named one by one, on purpose. The alternative is the "kernel-modules"
# meta-package, which is what the rauc bbappend was dragging in: 1732
# packages, tens of megabytes, and a depmod pass over all of it at every
# boot. A handful of named modules is ~150 KB and says out loud which
# hardware this product supports.
#
#   cdc-acm    USB CDC-ACM. What the Raspberry Pi Debugprobe on the bench
#              enumerates as (2e8a:000c -> /dev/ttyACM0). Also most Arduino-
#              class boards and anything speaking the USB serial class
#              natively rather than through a bridge chip.
#   usbserial  The USB-serial CORE. Not a driver for any chip; it is the
#              framework the bridge drivers below are built on.
#   ftdi-sio   FTDI FT232/FT2232 etc. The classic blue USB-serial dongles.
#   cp210x     Silicon Labs CP2102/CP2104. Common on ESP32 dev boards.
#   ch341      WCH CH340/CH341. Ubiquitous on cheap clone boards.
#   pl2303     Prolific PL2303. See below — this is the one that was missing,
#              and it is the one the actual work adapter needs.
#
# ---------------------------------------------------------------------------
# WHY pl2303 IS HERE  (session 26)
# ---------------------------------------------------------------------------
# The first time this image met the real work adapter, no /dev/ttyUSB0
# appeared and nothing was logged. The adapter turned out to be:
#
#     Bus 001 Device 004: ID 067b:2303 Prolific Technology, Inc. PL2303
#
# and the card carried exactly four modules under drivers/usb/serial:
#
#     ch341.ko.xz  cp210x.ko.xz  ftdi_sio.ko.xz  usbserial.ko.xz
#
# No pl2303. So there was no driver to bind, no tty to create, and nothing
# for the udev rule to match — a silent failure at the very bottom of the
# stack, below every layer that has any diagnostics in it.
#
# This was a plain omission, not a subtlety. The comment that used to sit
# here claimed these drivers "cover essentially every USB-serial adapter you
# can buy" while leaving out one of the two most common cheap bridges on the
# market. Prolific and WCH split that market between them; shipping ch341
# without pl2303 covers half of it and reads as if it covers all of it.
#
# ---------------------------------------------------------------------------
# A WRONG GUESS WORTH KEEPING, BECAUSE IT LOOKED SO GOOD
# ---------------------------------------------------------------------------
# Before the adapter was identified, the failure was blamed on usbserial.
# The argument: cdc-acm is a COMPLETE driver that registers a tty by itself,
# while every bridge driver is only half a thing and delegates the tty
# machinery to usbserial.ko. So the bench test (a Debugprobe, cdc-acm) had
# exercised the one path in this image that does not need usbserial, and
# proved nothing about the other three. Elegant, matched every symptom, and
# had a precedent right below in the brcmfmac-wcc note.
#
# It was wrong. On the board:
#
#     # modprobe ftdi_sio
#     # lsmod
#     ftdi_sio               45056  0
#     usbserial              36864  1 ftdi_sio
#
# usbserial came in on its own, because kernel-module-split DID generate the
# dependency from modinfo — the thing the brcmutil note below says it
# "should" do. It does. The lesson from brcmfmac-wcc is narrower than it
# looked: what split cannot see is a RUNTIME request_module(), not an
# ordinary link-time module dependency.
#
# usbserial stays named anyway, for the same one-line reason brcmutil is
# named. It is documentation, not a fix, and it should not be mistaken for
# one.
#
# On the package names: the real packages are versioned
# (kernel-module-cdc-acm-6.6.63), and each one RPROVIDES the unversioned
# name. Naming the unversioned form here is therefore both valid and
# deliberate — it survives a kernel bump, where the versioned name would
# turn into an unresolvable dependency on the day meta-raspberrypi moves
# to 6.12.
#
# The udev rule in serial-logger matches by ANCESTRY
# (SUBSYSTEM=="tty", SUBSYSTEMS=="usb"), not by driver name, so it already
# handles a driver we haven't installed yet without being edited. The module
# list and the udev rule are deliberately decoupled that way — which is also
# why the pl2303 failure was silent at the udev layer: there was no tty to
# match, so there was nothing for the rule to be wrong about.
LOGGER_USB_SERIAL_MODULES = "\
    kernel-module-cdc-acm \
    kernel-module-usbserial \
    kernel-module-ftdi-sio \
    kernel-module-cp210x \
    kernel-module-ch341 \
    kernel-module-pl2303 \
    "

# --- WiFi -------------------------------------------------------------------
#
# THIS BLOCK IS NOT OPTIONAL BOILERPLATE. Leaving it out produces an image
# that boots fine, has a wlan0-shaped hole, and cannot be reached at all on
# a board with no ethernet port.
#
# The trap: raspberrypi0-wifi.conf DOES declare the firmware —
#
#     MACHINE_EXTRA_RRECOMMENDS += " \
#         linux-firmware-rpidistro-bcm43430 \
#         bluez-firmware-rpidistro-bcm43430a1-hcd"
#
# — but MACHINE_EXTRA_RRECOMMENDS is consumed by packagegroup-BASE, and
# packagegroup-core-BOOT consumes MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS.
# Different variable, different packagegroup. A core-boot-based image on
# this machine therefore gets no WiFi firmware whatsoever, and the machine
# conf's declaration is silently inert.
#
# That is not a theory. In build-rpi0, after a full core-image-minimal
# build, tmp/deploy/rpm/ contains no linux-firmware-rpidistro-bcm43430 rpm
# at all — the recipe was never even built, because nothing in the image
# graph asked for it.
#
# "rpidistro" rather than poky's linux-firmware-bcm43430: it is the
# Raspberry Pi Foundation's own blob for this SDIO part, which is what
# meta-raspberrypi points the machine at. Take the BSP's word for it.
#
# brcmutil is listed alongside brcmfmac deliberately. brcmfmac cannot load
# without it, and while kernel-module-split should generate that dependency
# from modinfo, naming it costs one line and removes the question.
#
# NOT included: bluez-firmware-rpidistro-bcm43430a1-hcd. This product has
# no use for Bluetooth, and on THIS board the radio is not free — the
# BCM43438 shares the SDIO bus with WiFi and owns the PL011 UART, which is
# the whole reason the serial console here is ttyS0 (the mini-UART) and the
# whole reason ENABLE_UART=1 pins core_freq to 250 MHz.
LOGGER_WIFI = "\
    kernel-module-brcmfmac \
    kernel-module-brcmfmac-wcc \
    kernel-module-brcmutil \
    linux-firmware-rpidistro-bcm43430 \
    wireless-regdb-static \
    wpa-supplicant \
    "

# --- Two additions the first boot forced, and what they cost -----------------
#
# kernel-module-brcmfmac-wcc
#
#   The first flash booted perfectly and had no wlan0. The journal said:
#
#     brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43430-sdio for chip BCM43430/1
#     brcmfmac: brcmf_fwvid_request_module: mod=wcc: failed 256
#     ieee80211 phy0: brcmf_attach: brcmf_fwvid_attach failed
#     brcmfmac: brcmf_sdio_firmware_callback: brcmf_attach failed
#
#   Linux 6.6 split brcmfmac's vendor-specific code into separate modules —
#   brcmfmac-wcc, brcmfmac-bca and brcmfmac-cyw are all built here. The core
#   module probes the chip, decides which VENDOR it is, and then
#   request_module()s that one at runtime. BCM43430 resolves to wcc, so
#   brcmfmac alone attaches to the SDIO device, reads the chip ID, and then
#   fails — which is why the failure looks like a firmware problem and is
#   not one. The blob loaded fine.
#
#   This is the bill for naming modules explicitly instead of installing
#   `kernel-modules`. Four USB drivers plus brcmfmac plus brcmutil looked
#   like the complete list, and a runtime request_module() dependency is
#   invisible to every static check we ran. Only wcc is added, not bca or
#   cyw: this board has one radio and the log names its vendor. If a future
#   board needs another, the log will say so in the same words.
#
# wireless-regdb-static
#
#   Same boot, quieter line:
#
#     platform regulatory.0: Direct firmware load for regulatory.db failed with error -2
#
#   Without the regulatory database the kernel falls back to the built-in
#   "world" domain, which is deliberately conservative — reduced TX power
#   and, in region 2.4 GHz, channels 12 and 13 unusable. Our
#   wpa_supplicant.conf sets country=, and that setting cannot take effect
#   with no database to look the country up in. On a router parked on
#   channel 12 or 13 this alone is enough to never associate.
#
#   The files live in the -static package, not the main one
#   (wireless-regdb_*.bb:29) — the main package is for the CRDA userspace
#   helper path, which modern kernels do not use.

# No locales. Same trick core-image-minimal uses to stay small, and on a
# headless logger there is nothing to localise.
IMAGE_LINGUAS = " "

# --- Drop the duplicate syslog daemon ----------------------------------------
#
# Found by reading the first boot's journal, where EVERY kernel line
# appears twice:
#
#   [21.268867] raspberrypi0-wifi kernel:      brcmfmac: F1 signature read ...
#   [21.281007] raspberrypi0-wifi kernel[181]: [21.268867] brcmfmac: F1 signature read ...
#
# PID 181 is busybox klogd. journald already reads /dev/kmsg directly, so
# klogd re-reads the same kernel ring buffer and re-injects every line as a
# syslog message, which journald then writes to disk a second time. Double
# the journal writes, onto an SD card, during boot.
#
# Look at the timestamps above and it is worse than redundant: the
# duplicate arrives at monotonic 21.28 quoting a kernel timestamp of 21.27,
# but the copies of the EARLY kernel messages land at ~18-19 s while
# quoting timestamps of 0-4 s. klogd spends the first 18 seconds of boot
# replaying the ring buffer into journald — CPU and I/O spent, on one
# ARM11 core, on the boot critical path, producing nothing.
#
# It is here at all because packagegroup-core-boot RRECOMMENDS
# ${VIRTUAL-RUNTIME_base-utils-syslog}, which default-providers.inc:31
# defaults to busybox-syslog. That default predates systemd being the
# normal case; with journald there is nothing left for it to do —
# systemd-journald-dev-log.socket already provides /dev/log for anything
# that logs the classic way.
#
# BAD_RECOMMENDATIONS rather than overriding VIRTUAL-RUNTIME_*: this is an
# image-level decision ("this OS does not want that package") and
# BAD_RECOMMENDATIONS is the image-level knob for dropping an RRECOMMENDS
# without touching the packagegroup that made it. Note it works with rpm
# and ipk but NOT deb (rootfs_deb.bbclass:19 warns and ignores it) — fine
# here, PACKAGE_CLASSES is package_rpm.
BAD_RECOMMENDATIONS += "busybox-syslog"

# --- Stop wic from rewriting our fstab ---------------------------------------
#
# The first boot's journal, before anything else went wrong:
#
#   systemd-fstab-generator[77]: Failed to create unit file
#     '/run/systemd/generator/boot.mount', as it already exists.
#     Duplicate entry in '/etc/fstab'?
#   (sd-exec-[75]: systemd-fstab-generator failed with exit status 1.
#
# The generator did not warn and carry on — it EXITED 1, meaning the whole
# fstab-to-units translation was abandoned for that boot.
#
# Cause: wic writes fstab entries of its own. update_fstab() in
# poky/scripts/lib/wic/plugins/imager/direct.py loops over every partition
# with a mountpoint other than "/" and APPENDS a line — with no check for
# whether that mountpoint is already in the file. So our carefully
# commented /boot line from
# recipes-core/base-files/files/raspberrypi0-wifi/fstab and wic's
# tab-separated generated one both ended up in /etc/fstab, naming the same
# device and the same mountpoint.
#
# Note this only bites because we HAVE a hand-written fstab. On a stock
# image wic's line is the only one and everything is fine, which is why
# this is not a known trap.
#
# Two ways to fix it. We could delete /boot from our fstab and let wic
# generate it, passing --fsopts to get "nofail" back. Instead: keep one
# file authoritative for the mount table and tell wic to keep its hands
# off. Our fstab explains WHY each line is there, applies to every image
# type rather than just the .wic, and nofail is a decision that deserves
# to live next to its reasoning.
#
# The switch is wic's command-line option, not the per-partition
# --no-fstab-update in ksparser.py — that flag exists but the loop above
# never consults it in scarthgap. image_types_wic.bbclass:73 passes
# WIC_CREATE_EXTRA_ARGS straight through to `wic create`, so no custom
# .wks is needed.
WIC_CREATE_EXTRA_ARGS += " --no-fstab-update"

# ---------------------------------------------------------------------------
# WHAT IS DELIBERATELY ABSENT, AND WHY
# ---------------------------------------------------------------------------
#
# package-management — playground-image has it (session 9), and it is how
#   serial-logger got onto the Pi 5 for testing. It drags in dnf, rpm and
#   python3. On an ARMv6 single-core with a 512 MB ceiling that is a large
#   fraction of the rootfs and a meaningful chunk of boot for a capability
#   this device will never use: it is reflashed, not updated. If we want it
#   back for a debug spin it is one line in local.conf's
#   EXTRA_IMAGE_FEATURES, which is the right place for "how I am iterating
#   today" as opposed to "what this product is".
#
# rauc / e2fsprogs-resize2fs — no A/B layout on this board, so no OTA
#   client and nothing to resize. Note the distro STILL sets
#   DISTRO_FEATURES:append = " rauc", which means this kernel is still
#   carrying dm-verity, squashfs, loop and nbd for a feature that is not
#   installed. That is a real lever and it is on the optimize list; it is
#   not pulled here because pulling it re-signs the kernel and we measure
#   before we optimise.
#
# hello / playground-pulse — learning artifacts. playground-pulse in
#   particular blinks an LED on GPIO17 via an overlay that this build does
#   not ship.
#
# NetworkManager — the single biggest line in the baseline: 43.0 s of an
#   86.9 s boot, with ssh ordered After=network.target behind it. This
#   image uses systemd-networkd (already in systemd, nothing to install)
#   plus wpa_supplicant directly. That is the one optimisation taken on
#   faith rather than measurement, and the baseline is the justification.
#
# The WiFi credential — the PSK is not here and will never be. This repo is
#   public. Nothing in this image knows the network's password; the
#   wpa_supplicant config is placed on the card by hand after flashing,
#   the same workflow as the SSH key. See notes/20.
#
# debug-tweaks — dev-workstation policy (empty root password), so it stays
#   in local.conf's EXTRA_IMAGE_FEATURES where a real build strips it.
#   Same boundary playground-image draws.
#
# systemd-analyze IS here, and it is the one thing in this list that will
#   come back out. It is the instrument for the "measure, then optimize"
#   checkbox. Once the numbers are in, it goes.
