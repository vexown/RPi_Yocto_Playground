# serial-logger_1.0.bb — the capstone's actual product.
#
# hello_1.0.bb (notes/07) was the same shape with nothing in it: one .c file,
# hand-written do_compile and do_install. This is that recipe grown up — it
# also ships a systemd template unit, a udev rule and a config file, which
# means it has to say things about packaging that hello never needed.
#
# What it replaces: a Python script in /home/blankmcu and a hand-written
# .service file in /etc/systemd/system, both created by hand on a running
# Raspberry Pi OS box and existing nowhere else. That is the difference this
# whole project is about — the deployed system is now reproducible from a
# git checkout instead of from memory.

SUMMARY = "Logs USB serial devices to timestamped files, one instance per device"
HOMEPAGE = "https://github.com/vexown/RPi_Yocto_Playground"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://serial-logger.c \
           file://serial-logger@.service \
           file://99-serial-logger.rules \
           file://serial-logger.default \
           file://capctl \
           "

# A lone file:// unpacks straight into ${WORKDIR} on scarthgap, so S points
# there. (Session 13 gotcha, still true: ${UNPACKDIR} is the styhead-and-later
# split and does not exist in this release.)
S = "${WORKDIR}"

# Brings in the packaging support for systemd units: it parses
# SYSTEMD_SERVICE, adds each named unit file to FILES individually, and
# generates the postinst/prerm that run `systemctl preset`/`disable`.
inherit systemd

# The template's real filename. systemd.bbclass understands the "@" —
# it explicitly handles deriving 'foo@.service' from a SYSTEMD_SERVICE entry,
# so naming the template here is correct and no instance needs listing.
SYSTEMD_SERVICE:${PN} = "serial-logger@.service"

# Nothing to enable. A template with no [Install] section has no enablement
# state, and udev is what starts instances (see 99-serial-logger.rules).
# Leaving this at the default "enable" would make the postinst try to
# `systemctl preset` a unit that cannot be preset.
SYSTEMD_AUTO_ENABLE = "disable"

do_compile() {
    # ${CC} is the cross-compiler for THIS machine — for the Zero W that
    # expands to arm-poky-linux-gnueabi-gcc with -march=armv6 -mfpu=vfp
    # -mfloat-abi=hard, which is a different compiler and a different ABI
    # from every build in phases 1-5. Never write "gcc" here.
    #
    # ${LDFLAGS} is mandatory, not decorative: without it do_package_qa
    # fails with "No GNU_HASH in the ELF binary" (learned the hard way in
    # session 7, documented in hello_1.0.bb).
    #
    # -Wall -Wextra -Werror is our own addition. The program is small enough
    # that there is no excuse for a warning in it, and a build failure on the
    # PC is infinitely cheaper than debugging a logger in the field.
    ${CC} ${CFLAGS} ${LDFLAGS} -Wall -Wextra -Werror \
        ${S}/serial-logger.c -o serial-logger
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/serial-logger ${D}${bindir}/serial-logger

    # capctl, the operator's side of the same product: a shell script, so
    # it is installed as-is, not compiled. Run it with no arguments for
    # its menu, or `capctl help` for the subcommands.
    install -m 0755 ${S}/capctl ${D}${bindir}/capctl

    # The unit goes in the VENDOR directory (/usr/lib/systemd/system), not
    # /etc/systemd/system. That distinction is a real one: /etc is the
    # administrator's, and anything we drop there we are taking away from
    # them. A unit shipped by a package belongs in the vendor dir, where the
    # admin can then override or mask it from /etc — which is exactly how
    # the deployed hand-written unit in /etc SHOULD have been done.
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/serial-logger@.service ${D}${systemd_system_unitdir}/

    # Same argument for udev: ${nonarch_base_libdir}/udev/rules.d is the
    # package-owned rules directory. /etc/udev/rules.d is for local
    # overrides, and a same-named file there beats ours — the escape hatch
    # an admin needs.
    install -d ${D}${nonarch_base_libdir}/udev/rules.d
    install -m 0644 ${S}/99-serial-logger.rules \
        ${D}${nonarch_base_libdir}/udev/rules.d/

    # ...and the config file DOES go in /etc, because it is the one thing
    # here that is genuinely the administrator's to change.
    install -d ${D}${sysconfdir}/default
    install -m 0644 ${S}/serial-logger.default \
        ${D}${sysconfdir}/default/serial-logger
}

# Mark the config file as a conffile so package upgrades don't silently
# stomp local edits to the baud rate.
CONFFILES:${PN} = "${sysconfdir}/default/serial-logger"

# No FILES:${PN} += needed here, and it is worth knowing why after session 13
# cost us a build over exactly this. bitbake.conf's default FILES:${PN}
# already covers ${bindir}/*, ${sysconfdir}, and both ${base_prefix}/lib/udev
# and ${prefix}/lib/udev. The unit file is the only path not covered by a
# default — and systemd.bbclass adds that one itself from SYSTEMD_SERVICE.

# The udev rule is inert without a udev to read it. systemd provides it in
# this image, but stating the dependency keeps the package honest if it is
# ever installed somewhere else.
# "+=" not "=": systemd.bbclass may contribute runtime dependencies of its
# own, and a plain assignment here would silently discard them.
RDEPENDS:${PN} += "udev"
