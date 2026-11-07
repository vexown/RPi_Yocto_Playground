SUMMARY = "Grows the serial logger's captures partition to fill the SD card"
DESCRIPTION = "First-boot step for rpi0-logger-image: extends mmcblk0p3 from \
the 64 MB the image ships to the end of whatever card it is on."
HOMEPAGE = "https://github.com/vexown/RPi_Yocto_Playground"
LICENSE = "MIT"
# Our own files, so the license text is poky's stock copy of MIT, checked by
# md5 so the build notices if it ever changes.
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# The partition itself is defined in meta-playground/wic/rpi0-logger.wks and
# mounted by the fstab in recipes-core/base-files/files/raspberrypi0-wifi/.
# This recipe is only the "grow it" step between those two.

# file:// means "from this recipe's files/ directory". Nothing is downloaded.
SRC_URI = "file://grow-captures \
           file://grow-captures.service \
           "

# Files from SRC_URI land in WORKDIR; there is no unpacked source tree.
S = "${WORKDIR}"

# systemd  packages the unit and handles SYSTEMD_SERVICE below.
# allarch  a shell script and a text file are the same on every CPU, so
#          build the package once for all architectures instead of per
#          machine.
inherit systemd allarch

# Which unit file the systemd class should package with ${PN}.
SYSTEMD_SERVICE:${PN} = "grow-captures.service"
# Do not enable it at image build time. The unit has no [Install] section
# anyway; it starts because the captures mount requires it
# (x-systemd.requires= in fstab). Same pattern as serial-logger@.service,
# which udev starts.
SYSTEMD_AUTO_ENABLE = "disable"

do_install() {
    # install -d   create the directory (and parents) inside the package
    #              staging area ${D}
    # install -m   copy a file and set its permissions: 0755 = executable,
    #              0644 = readable by all, writable by root
    install -d ${D}${sbindir}
    install -m 0755 ${S}/grow-captures ${D}${sbindir}/grow-captures

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/grow-captures.service ${D}${systemd_system_unitdir}/
}

# The tools the script runs: sfdisk writes the new table, partx reads the
# new length back, resizepart hands it to the kernel. BusyBox has none of
# them in a usable form (its fdisk is interactive-only). These are the
# util-linux versions, which poky splits into one package per tool, so this
# pulls in only these three and not all of util-linux.
RDEPENDS:${PN} = "util-linux-sfdisk util-linux-partx util-linux-resizepart"
