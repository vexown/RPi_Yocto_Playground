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
    "

# --- The USB serial drivers -------------------------------------------------
#
# Named one by one, on purpose. The alternative is the "kernel-modules"
# meta-package, which is what the rauc bbappend was dragging in: 1732
# packages, tens of megabytes, and a depmod pass over all of it at every
# boot. Four named modules is ~100 KB and says out loud which hardware this
# product supports.
#
#   cdc-acm   USB CDC-ACM. What the Raspberry Pi Debugprobe on the bench
#             enumerates as (2e8a:000c -> /dev/ttyACM0). Also most Arduino-
#             class boards and anything speaking the USB serial class
#             natively rather than through a bridge chip.
#   ftdi-sio  FTDI FT232/FT2232 etc. The classic blue USB-serial dongles.
#   cp210x    Silicon Labs CP2102/CP2104. Common on ESP32 dev boards.
#   ch341     WCH CH340/CH341. Ubiquitous on cheap clone boards.
#
# Together those four cover essentially every USB-serial adapter you can
# buy. Adding a fifth later is one line here plus a reflash — cheaper than
# shipping all 1732 forever on the chance that one day you need one.
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
# handles a driver we haven't installed yet without being edited. The
# module list and the udev rule are deliberately decoupled that way.
LOGGER_USB_SERIAL_MODULES = "\
    kernel-module-cdc-acm \
    kernel-module-ftdi-sio \
    kernel-module-cp210x \
    kernel-module-ch341 \
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
    kernel-module-brcmutil \
    linux-firmware-rpidistro-bcm43430 \
    wpa-supplicant \
    "

# No locales. Same trick core-image-minimal uses to stay small, and on a
# headless logger there is nothing to localise.
IMAGE_LINGUAS = " "

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
