# playground-pulse — install + enable a systemd service via our layer.
#
# Third recipe archetype for us: hello_1.0.bb = rootfs package (code),
# playground-led-overlay = boot partition cargo, this = rootfs package
# that hooks into the init system. The interesting part is `inherit
# systemd`: the SAME class dropbear uses (session 3's question!). Its
# behavior is gated on "systemd" in DISTRO_FEATURES — on our old
# sysvinit builds it would do nothing (even actively delete unit dirs);
# with INIT_MANAGER = "systemd" it packages the unit AND enables it at
# IMAGE BUILD TIME (no first-boot "systemctl enable" needed — the
# enable-symlink is created while the rootfs is assembled).

SUMMARY = "Boot service: switch the playground LED to the heartbeat trigger"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://playground-pulse.service"

inherit systemd

# Which unit(s) this package owns. The class finds the file in
# systemd_system_unitdir at package time (and fails the build if the
# name doesn't match — try a typo sometime). SYSTEMD_AUTO_ENABLE
# defaults to "enable"; set it to "disable" to ship a unit dormant.
SYSTEMD_SERVICE:${PN} = "playground-pulse.service"

do_install() {
    # systemd_system_unitdir = /usr/lib/systemd/system with usrmerge.
    # Same install idiom as hello, different well-known destination.
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/playground-pulse.service ${D}${systemd_system_unitdir}/
}
