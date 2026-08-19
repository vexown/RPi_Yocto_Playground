# rpi0-network_1.0.bb — the Zero W's entire network stack configuration.
#
# Five small files, and between them they replace NetworkManager:
#
#   20-wlan0.network             layer 3 (address, route, DNS) via networkd
#   97-rpi0-logger-net.preset    switches on the supplicant template
#   10-default-instance.conf     drop-in saying WHICH instance that means
#   wpa_supplicant-wlan0.conf.example   documentation of the file we refuse
#                                       to ship
#   10-wifi-early.conf           loads brcmfmac at 8 s instead of 17 s
#
# The last two are one mechanism split across two files, and the split is
# not decoration — see 10-default-instance.conf for the silent no-op that
# made it necessary.
#
# The baseline this is aimed at: NetworkManager was 43.0 s of an 86.9 s
# boot on the deployed Raspberry Pi OS card, with sshd ordered behind it
# on network.target. Nothing here is a daemon we add — networkd is already
# inside the systemd package and already enabled by upstream's preset, and
# wpa_supplicant is a package the board needs regardless. The cost of this
# recipe is three text files.

SUMMARY = "WiFi and networkd configuration for the Pi Zero W logger"
DESCRIPTION = "systemd-networkd + wpa_supplicant configuration replacing \
NetworkManager. Contains no credentials — the PSK is provisioned onto the \
card after flashing, never built into the image."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://20-wlan0.network \
           file://97-rpi0-logger-net.preset \
           file://10-default-instance.conf \
           file://wpa_supplicant-wlan0.conf.example \
           file://10-wifi-early.conf \
           "

S = "${WORKDIR}"

# This recipe is pure configuration — no compiler runs, nothing
# architecture-specific comes out of it. Saying so has two effects worth
# understanding:
#
#   allarch.bbclass sets PACKAGE_ARCH = "all", so the resulting .rpm is
#   shared between the ARMv6 Zero W build and the ARMv8 Pi 5 build instead
#   of being built twice. It also skips the QA checks that look for
#   binaries with the wrong architecture, which would otherwise have
#   nothing to check.
#
# The honest caveat: the CONTENT of this package is machine-specific in
# spirit (it says "wlan0", it is named rpi0-network). allarch is about
# whether the BITS depend on the target architecture, and they don't. The
# machine-specificity is enforced by simply not putting this recipe in the
# Pi 5's image.
inherit allarch

do_install() {
    # networkd's config directory. /etc is correct here rather than the
    # vendor dir at ${systemd_unitdir}/network: this is the integrator's
    # network policy for this box, and an admin editing it in place is a
    # supported thing to do.
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${S}/20-wlan0.network ${D}${sysconfdir}/systemd/network/

    # The preset, in the vendor directory. This one is NOT admin config —
    # it is a packaging statement ("this image wants that unit on"), and
    # it is consumed once, at image-assembly time, by
    # `systemctl preset-all`. It never gets read on the target.
    install -d ${D}${systemd_unitdir}/system-preset
    install -m 0644 ${S}/97-rpi0-logger-net.preset \
        ${D}${systemd_unitdir}/system-preset/

    # The drop-in that gives wpa_supplicant@.service a DefaultInstance.
    # Vendor dir, next to the unit it extends: this is packaging, not admin
    # policy, and an admin who disagrees can shadow it from
    # /etc/systemd/system/wpa_supplicant@.service.d/ where drop-ins of the
    # same name win.
    install -d ${D}${systemd_system_unitdir}/wpa_supplicant@.service.d
    install -m 0644 ${S}/10-default-instance.conf \
        ${D}${systemd_system_unitdir}/wpa_supplicant@.service.d/

    # /etc/wpa_supplicant/ — created here, deliberately EMPTY apart from
    # the example. wpa_supplicant@wlan0.service will look for
    # wpa_supplicant-wlan0.conf in it and, on a freshly flashed card, not
    # find it: the unit fails, and boot carries on. That is the correct
    # behaviour and it is not papered over. An image that shipped a
    # placeholder config would associate with nothing while looking
    # configured, which is worse.
    #
    # 0700: the real file that lands here is password-equivalent. The
    # directory permission is the backstop for the file permission.
    install -d -m 0700 ${D}${sysconfdir}/wpa_supplicant
    install -m 0600 ${S}/wpa_supplicant-wlan0.conf.example \
        ${D}${sysconfdir}/wpa_supplicant/

    # modules-load.d, in the VENDOR directory (/usr/lib), for the same
    # reason the preset and the drop-in live there: this is a statement
    # by the image about how it wants to boot, not a policy the operator
    # of a particular box chose. systemd-modules-load.service reads
    # /etc/modules-load.d first, so an admin who disagrees can shadow this
    # by dropping a file of the same name into /etc and win.
    #
    # ${nonarch_libdir} rather than ${libdir}: on a multilib build
    # ${libdir} can become /usr/lib64, and systemd looks in /usr/lib
    # regardless of word size. Configuration is not architecture-specific
    # and must not follow the library path.
    install -d ${D}${nonarch_libdir}/modules-load.d
    install -m 0644 ${S}/10-wifi-early.conf \
        ${D}${nonarch_libdir}/modules-load.d/
}

# Default FILES:${PN} covers ${sysconfdir} but NOT ${systemd_unitdir}
# (/usr/lib/systemd) — that path is normally claimed by systemd.bbclass on
# behalf of recipes that ship units, and this recipe ships no units, so it
# doesn't inherit systemd and has to claim these paths itself.
#
# The drop-in directory is named precisely rather than claiming all of
# ${systemd_system_unitdir}: this package has no business owning a path
# that poky's own systemd and wpa-supplicant packages populate, and an
# overly greedy FILES is how two packages end up fighting over a directory.
FILES:${PN} += "${systemd_unitdir}/system-preset \
                ${systemd_system_unitdir}/wpa_supplicant@.service.d \
                ${nonarch_libdir}/modules-load.d \
                "

# The .network file is genuinely the administrator's to edit — mark it so
# a package upgrade doesn't stomp a hand-tuned static address.
CONFFILES:${PN} = "${sysconfdir}/systemd/network/20-wlan0.network"

# The preset enables wpa_supplicant@wlan0.service, so the package that
# provides that unit had better be installed. Without this line the preset
# is a silent no-op: `systemctl preset-all` skips units it cannot find,
# and the image builds clean with no WiFi.
RDEPENDS:${PN} += "wpa-supplicant"
