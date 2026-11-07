SUMMARY = "Caps the persistent systemd journal at 8 MB on the Pi Zero W logger"
HOMEPAGE = "https://github.com/vexown/RPi_Yocto_Playground"
LICENSE = "MIT"
# Our own file, so the license text is poky's stock copy of MIT, checked by
# md5 so the build notices if it ever changes.
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# file:// means "from this recipe's files/ directory". Nothing is downloaded.
SRC_URI = "file://50-size-cap.conf"

# Files from SRC_URI land in WORKDIR; there is no unpacked source tree.
S = "${WORKDIR}"

# A text file is the same on every CPU: build the package once for all
# architectures instead of per machine.
inherit allarch

# A drop-in, not an edit of journald.conf. journald reads
# /etc/systemd/journald.conf, then every *.conf in journald.conf.d/ on top,
# in name order (hence the "50-" prefix: room before and after it). So this
# recipe does not touch the systemd recipe at all: no systemd rebuild (the
# slowest recipe in this image), and no conflict with the journald.conf
# systemd itself installs.
#
# Its own recipe, rather than a line in systemd_%.bbappend, also scopes it:
# only an image that installs journald-size-cap gets the cap. That is
# rpi0-logger-image; the Pi 5 images are unaffected.
do_install() {
    # install -d   create the directory inside the package staging area ${D}
    # install -m   copy the file, readable by all, writable by root (0644)
    install -d ${D}${sysconfdir}/systemd/journald.conf.d
    install -m 0644 ${S}/50-size-cap.conf \
        ${D}${sysconfdir}/systemd/journald.conf.d/50-size-cap.conf
}

# Which installed files belong in the package. Without this line the file
# would land in no package and the build would stop with an
# "installed but not shipped" error.
FILES:${PN} = "${sysconfdir}/systemd/journald.conf.d/50-size-cap.conf"
