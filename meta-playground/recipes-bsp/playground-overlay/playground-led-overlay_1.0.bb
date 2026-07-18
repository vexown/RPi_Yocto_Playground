# playground-led-overlay — compile our device tree overlay and DEPLOY it.
#
# A new recipe archetype for us. hello_1.0.bb produced a PACKAGE that gets
# installed into the rootfs; this recipe produces BOOT PARTITION CARGO.
# Different destination, different mechanism: the deploy class. do_deploy
# drops artifacts into DEPLOY_DIR_IMAGE (tmp/deploy/images/<machine>/),
# and the image's IMAGE_BOOT_FILES list (see local.conf) copies them into
# the FAT32 boot partition when the .wic image is assembled. The kernel
# and rpi-bootfiles reach the boot partition the exact same way.

SUMMARY = "Custom device tree overlay: an LED on GPIO17 (see playground-led.dts)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://playground-led.dts"
S = "${WORKDIR}"

# dtc-native = the device tree compiler, built FOR the build host (that's
# what -native means) — same tool as Ubuntu's device-tree-compiler package.
# DEPENDS drops it into this recipe's private recipe-sysroot-native/.
DEPENDS = "dtc-native"

# deploy: gives us the do_deploy machinery described above.
# nopackages: skip do_package* entirely — nothing here goes in the rootfs,
# so there is nothing to package.
inherit deploy nopackages

# The .dtbo is board-specific cargo, not "any aarch64" — tie it to the
# machine so sstate files it under raspberrypi5, like the kernel's dtbs.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Nothing to configure or install; tell bitbake instead of leaving empty
# functions (noexec tasks show as such in logs and cost nothing).
do_configure[noexec] = "1"
do_install[noexec] = "1"

do_compile() {
    # -@ keeps symbols so this overlay could itself be referenced by
    # another; -I/-O = input/output formats (same flags as when we
    # decompiled the live tree, just pointing the other way).
    dtc -@ -I dts -O dtb -o ${B}/playground-led.dtbo ${S}/playground-led.dts
}

do_deploy() {
    install -D -m 0644 ${B}/playground-led.dtbo ${DEPLOYDIR}/playground-led.dtbo
}
# Wire the task into the flow: deploy class defines do_deploy but each
# recipe decides where it sits in its task chain.
addtask deploy after do_compile before do_build
